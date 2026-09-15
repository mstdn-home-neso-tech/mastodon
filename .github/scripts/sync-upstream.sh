#!/usr/bin/env bash
#
# upstream (mastodon/mastodon の main) を develop に取り込む。
# .github/workflows/sync-upstream.yml から毎日実行される。
#
#   1. upstream に新しいコミットが無ければ何もしない
#   2. 未マージの sync PR (sync-upstream-*) が open なら何もしない (先にそれを片付ける)
#   3. develop に upstream をマージし、sync-upstream-YYYYMMDD ブランチとして push して PR を作る
#      - コンフリクト無し  -> auto-merge を有効化 (必須チェックが通れば自動でマージされる)
#      - コンフリクト有り  -> コンフリクトマーカー入りのまま draft PR を作り、人が PR 上で解決する
#        ※ fork 側で削除済み・upstream 側で変更されたファイル (modify/delete) は
#           「削除を維持」で自動解決する (AUTO_RESOLVE_DELETED_BY_US=false で無効化)
#
# 必要な環境変数:
#   GH_TOKEN                    gh CLI 用トークン (PR 作成 / マージ / ラベル)
# 任意:
#   UPSTREAM_REPO               既定 mastodon/mastodon
#   UPSTREAM_BRANCH             既定 main
#   BASE_BRANCH                 既定 develop
#   BRANCH_PREFIX               既定 sync-upstream-
#   PR_LABEL                    既定 upstream-sync
#   AUTO_RESOLVE_DELETED_BY_US  既定 true
#   DRY_RUN                     true にすると push と gh 操作を行わない (マージ結果の確認用)

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-mastodon/mastodon}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/${UPSTREAM_REPO}.git}"
BASE_BRANCH="${BASE_BRANCH:-develop}"
BRANCH_PREFIX="${BRANCH_PREFIX:-sync-upstream-}"
PR_LABEL="${PR_LABEL:-upstream-sync}"
AUTO_RESOLVE_DELETED_BY_US="${AUTO_RESOLVE_DELETED_BY_US:-true}"
DRY_RUN="${DRY_RUN:-false}"

if [ -z "${GH_REPO:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  export GH_REPO="$GITHUB_REPOSITORY"
fi

log()     { printf '[sync-upstream] %s\n' "$*" >&2; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi; }
output()  { if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi; }
short()   { printf '%s' "${1:0:7}"; }

# ---------------------------------------------------------------------------
# 1. fetch
# ---------------------------------------------------------------------------
git fetch --quiet origin "$BASE_BRANCH"
if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "$UPSTREAM_URL"
fi
git fetch --quiet upstream "$UPSTREAM_BRANCH"

BASE_REF="origin/${BASE_BRANCH}"
UP_REF="upstream/${UPSTREAM_BRANCH}"
BASE_SHA=$(git rev-parse "$BASE_REF")
UP_SHA=$(git rev-parse "$UP_REF")
MERGE_BASE=$(git merge-base "$BASE_REF" "$UP_REF")
NEW_COUNT=$(git rev-list --count "${BASE_REF}..${UP_REF}")
OWN_COUNT=$(git rev-list --count "${UP_REF}..${BASE_REF}")
COMPARE_URL="https://github.com/${UPSTREAM_REPO}/compare/${MERGE_BASE}...${UP_SHA}"

log "${BASE_BRANCH}=$(short "$BASE_SHA") ${UP_REF}=$(short "$UP_SHA") new=${NEW_COUNT} own=${OWN_COUNT}"

if [ "$NEW_COUNT" -eq 0 ]; then
  log "up to date; nothing to do"
  output result up-to-date
  summary "### upstream 同期: 差分なし"
  summary "\`${BASE_BRANCH}\` は \`${UPSTREAM_REPO}\` \`${UPSTREAM_BRANCH}\` ($(short "$UP_SHA")) を既に含んでいます。"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. 未マージの sync PR があればスキップ
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" != true ]; then
  OPEN_PRS=$(gh pr list --state open --base "$BASE_BRANCH" --limit 50 --json number,url,headRefName \
    --jq ".[] | select(.headRefName | startswith(\"${BRANCH_PREFIX}\")) | \"- #\\(.number) \\(.url)\"")
  if [ -n "$OPEN_PRS" ]; then
    log "open sync PR exists; skipping until it is merged or closed:"
    log "$OPEN_PRS"
    output result skipped-open-pr
    summary "### upstream 同期: スキップ (未マージの sync PR あり)"
    summary "upstream には ${NEW_COUNT} 件の新しいコミットがありますが、先に以下の PR をマージまたはクローズしてください。"
    summary ""
    summary "$OPEN_PRS"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# 3. ブランチ作成とマージ
# ---------------------------------------------------------------------------
TODAY=$(date -u +%Y-%m-%d)
BRANCH="${BRANCH_PREFIX}$(date -u +%Y%m%d)"
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  BRANCH="${BRANCH}-$(date -u +%H%M%S)"
fi

git config merge.renameLimit 100000
git checkout --quiet -B "$BRANCH" "$BASE_REF"

MERGE_MSG="Merge upstream ${UPSTREAM_REPO} ${UPSTREAM_BRANCH} into ${BASE_BRANCH}"
AUTO_RESOLVED=()   # 削除を維持したファイル
CONFLICTS=()       # "path<TAB>kind"

if git merge --no-ff --no-edit -m "$MERGE_MSG" "$UP_REF"; then
  STATUS=clean
else
  # git ls-files -u: "<mode> <sha> <stage>\t<path>"  stage 1=base 2=ours(fork) 3=theirs(upstream)
  declare -A HAS1=() HAS2=() HAS3=()
  PATHS=()
  while IFS= read -r -d '' entry; do
    meta=${entry%%$'\t'*}
    path=${entry#*$'\t'}
    stage=${meta##* }
    case "$stage" in
      1) HAS1[$path]=1 ;;
      2) HAS2[$path]=1 ;;
      3) HAS3[$path]=1 ;;
    esac
    PATHS+=("$path")
  done < <(git ls-files -u -z)

  if [ "${#PATHS[@]}" -eq 0 ]; then
    log "merge failed but there are no unmerged paths; aborting"
    git merge --abort || true
    exit 1
  fi
  mapfile -t PATHS < <(printf '%s\n' "${PATHS[@]}" | sort -u)

  for path in "${PATHS[@]}"; do
    if [ -n "${HAS1[$path]:-}" ] && [ -z "${HAS2[$path]:-}" ] && [ -n "${HAS3[$path]:-}" ]; then
      kind="deleted by us (fork で削除 / upstream で変更)"
      if [ "$AUTO_RESOLVE_DELETED_BY_US" = true ]; then
        git rm --quiet -- "$path"
        AUTO_RESOLVED+=("$path")
        continue
      fi
    elif [ -n "${HAS1[$path]:-}" ] && [ -n "${HAS2[$path]:-}" ] && [ -z "${HAS3[$path]:-}" ]; then
      kind="deleted by them (fork で変更 / upstream で削除)"
    elif [ -z "${HAS1[$path]:-}" ]; then
      kind="both added"
    else
      kind="both modified"
    fi
    CONFLICTS+=("${path}"$'\t'"${kind}")
  done

  if [ "${#CONFLICTS[@]}" -eq 0 ]; then
    git commit --quiet --no-edit
    STATUS=clean
  else
    # 残りのコンフリクトはマーカー入りのままコミットし、人が PR 上で解決する
    git diff --name-only --diff-filter=U -z | xargs -0 git add --
    git commit --quiet -m "${MERGE_MSG} (unresolved conflicts: ${#CONFLICTS[@]} files)"
    STATUS=conflict
  fi
fi

MERGE_SHA=$(git rev-parse HEAD)
log "status=${STATUS} branch=${BRANCH} merge=$(short "$MERGE_SHA") auto-resolved=${#AUTO_RESOLVED[@]} conflicts=${#CONFLICTS[@]}"

# ---------------------------------------------------------------------------
# 4. PR 本文
# ---------------------------------------------------------------------------
BODY_FILE=$(mktemp)
{
  echo "## 概要"
  echo
  echo "upstream \`${UPSTREAM_REPO}\` の \`${UPSTREAM_BRANCH}\` を \`${BASE_BRANCH}\` に取り込む自動同期です (\`.github/workflows/sync-upstream.yml\`)。"
  echo
  echo "- 取り込み範囲: \`$(short "$MERGE_BASE")..$(short "$UP_SHA")\` (**${NEW_COUNT} commits**) — [upstream の差分を見る](${COMPARE_URL})"
  echo "- \`${BASE_BRANCH}\` 側の独自コミット: ${OWN_COUNT} commits (\`$(short "$BASE_SHA")\`)"
  echo
  if [ "${#AUTO_RESOLVED[@]}" -gt 0 ]; then
    echo "## 自動解決したコンフリクト (${#AUTO_RESOLVED[@]} ファイル)"
    echo
    echo "upstream で変更されましたが fork 側で削除済みのため、**削除を維持**しました。"
    echo
    for p in "${AUTO_RESOLVED[@]}"; do echo "- \`${p}\`"; done
    echo
  fi
  if [ "$STATUS" = conflict ]; then
    echo "## :warning: 未解決のコンフリクト (${#CONFLICTS[@]} ファイル)"
    echo
    echo "この PR は **draft** です。以下のファイルはコンフリクトマーカー (\`<<<<<<<\` / \`=======\` / \`>>>>>>>\`) が入ったままコミットされています。"
    echo "\`both modified\` 以外 (削除系・バイナリ) はマーカーが入らず fork 側の内容のままなので、内容を確認して判断してください。"
    echo
    echo "| ファイル | 種別 |"
    echo "| --- | --- |"
    for c in "${CONFLICTS[@]}"; do
      echo "| \`${c%%$'\t'*}\` | ${c#*$'\t'} |"
    done
    echo
    echo "### 解決手順"
    echo
    echo '```bash'
    echo "git fetch origin"
    echo "git switch ${BRANCH}"
    echo "# 上記ファイルのマーカーを解消する (lock ファイルは yarn install / bundle lock で再生成)"
    echo "git add -A && git commit -m 'Resolve upstream merge conflicts'"
    echo "git push"
    echo '```'
    echo
    echo "解決したら **Ready for review** にして CI を確認し、マージしてください。Claude Code に解決させる場合はこの PR の URL を渡してください。"
    echo
  else
    echo "## コンフリクト"
    echo
    echo "なし。auto-merge を有効化しているので、必須チェックが通れば自動でマージされます。"
    echo
  fi
  if [ "${USING_PAT:-}" = false ]; then
    echo "> [!NOTE]"
    echo "> この PR は \`GITHUB_TOKEN\` で作成されたため、\`pull_request\` トリガーの CI は起動しません。"
    echo "> CI を回すにはリポジトリの secret \`SYNC_UPSTREAM_TOKEN\` に PAT (fine-grained: Contents / Pull requests / Workflows = write、classic: repo + workflow) を設定してください。"
    echo
  fi
} > "$BODY_FILE"

TITLE="Merge upstream ${UPSTREAM_REPO} ${UPSTREAM_BRANCH} into ${BASE_BRANCH} (${TODAY})"
if [ "$STATUS" = conflict ]; then
  TITLE="[conflict] ${TITLE}"
fi

output result "$STATUS"
output branch "$BRANCH"

if [ "$DRY_RUN" = true ]; then
  log "DRY_RUN: not pushing. PR title would be: ${TITLE}"
  log "PR body:"
  cat "$BODY_FILE" >&2
  summary "### upstream 同期 (dry run): ${STATUS}"
  summary ""
  summary "$(cat "$BODY_FILE")"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. push と PR 作成
# ---------------------------------------------------------------------------
if ! git push --quiet -u origin "$BRANCH"; then
  log "push failed. upstream の変更に .github/workflows/ が含まれる場合、GITHUB_TOKEN では push できません。"
  log "secret SYNC_UPSTREAM_TOKEN に workflows: write 権限付きの PAT を設定してください。"
  exit 1
fi

LABEL_ARGS=()
if gh label create "$PR_LABEL" --color 0E8A16 --description "upstream からの自動同期 PR" --force >/dev/null 2>&1; then
  LABEL_ARGS=(--label "$PR_LABEL")
else
  log "could not create label ${PR_LABEL}; creating PR without label"
fi

DRAFT_ARGS=()
if [ "$STATUS" = conflict ]; then
  DRAFT_ARGS=(--draft)
fi

PR_URL=$(gh pr create --base "$BASE_BRANCH" --head "$BRANCH" --title "$TITLE" --body-file "$BODY_FILE" "${LABEL_ARGS[@]}" "${DRAFT_ARGS[@]}")
log "created ${PR_URL}"
output pr_url "$PR_URL"

if [ "$STATUS" = conflict ]; then
  summary "### upstream 同期: コンフリクトあり -> draft PR を作成"
  summary ""
  summary "${PR_URL} で ${#CONFLICTS[@]} ファイルのコンフリクトを解決してください。"
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. auto-merge
# ---------------------------------------------------------------------------
# 作成直後は mergeable が UNKNOWN のことがあるので少し待つ
for _ in $(seq 1 12); do
  mergeable=$(gh pr view "$PR_URL" --json mergeable --jq .mergeable 2>/dev/null || echo UNKNOWN)
  [ "$mergeable" != UNKNOWN ] && break
  sleep 5
done

if gh pr merge "$PR_URL" --merge --auto; then
  # 必須チェックが無く即マージ可能なら gh はその場でマージし、そうでなければ auto-merge を予約する
  log "auto-merge enabled (or merged) for ${PR_URL}"
  summary "### upstream 同期: コンフリクトなし -> auto-merge"
  summary ""
  summary "${PR_URL} (${NEW_COUNT} commits) を auto-merge に設定しました。"
elif gh pr merge "$PR_URL" --merge; then
  log "merged ${PR_URL}"
  summary "### upstream 同期: コンフリクトなし -> マージ済み"
  summary ""
  summary "${PR_URL} (${NEW_COUNT} commits) をマージしました。"
else
  log "::warning::could not enable auto-merge for ${PR_URL}; merge it manually"
  gh pr comment "$PR_URL" --body "auto-merge を有効化できませんでした。リポジトリ設定 (Settings > General > Pull Requests) で **Allow auto-merge** を有効にするか、手動でマージしてください。" || true
  summary "### upstream 同期: PR 作成済み (auto-merge 失敗)"
  summary ""
  summary "${PR_URL} を手動でマージしてください。"
fi
