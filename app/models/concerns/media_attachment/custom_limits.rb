# frozen_string_literal: true

# 自鯖用カスタム: メディアアップロード上限の緩和
#
# 上流 (mastodon/mastodon) には存在しない、このフォーク専用のファイル。
# app/models/media_attachment.rb は `include MediaAttachment::CustomLimits` の
# 1 行を除いて上流と同一に保ち、自鯖固有の値はすべてここに置く。
# 上流追従で media_attachment.rb をまるごと上流に合わせても、その 1 行さえ
# 残せばカスタム値が維持される（この部分だけは上流に追従しない）。
#
# include の位置には制約がある。
#   - 上流の IMAGE_LIMIT / VIDEO_LIMIT / MAX_VIDEO_* と IMAGE_STYLES の定義より後
#   - それらを参照する IMAGE_CONVERTED_STYLES / VIDEO_FORMAT /
#     validates_attachment_size / remotable_attachment より前
# include が消えたり位置がずれたりして効かなくなった場合は
# spec/models/concerns/media_attachment/custom_limits_spec.rb が落ちる。
module MediaAttachment::CustomLimits
  extend ActiveSupport::Concern

  # 定数名 => 自鯖での値（コメントは上流の値）
  LIMITS = {
    IMAGE_LIMIT: 80.megabytes, # 上流: 16MB
    VIDEO_LIMIT: 400.megabytes, # 上流: 99MB
    MAX_VIDEO_MATRIX_LIMIT: 33_177_600, # 上流: 8_294_400 (3840x2160px) → 7680x4320px
    MAX_VIDEO_FRAME_RATE: 240, # 上流: 120
    MAX_VIDEO_FRAMES: 72_000, # 上流: 36_000 (120fps で約 5 分) → 240fps で約 5 分
  }.freeze

  # 画像 (original スタイル) を縮小せずに保持する画素数の上限。上流: 8_294_400 (3840x2160px)
  IMAGE_ORIGINAL_PIXELS = LIMITS[:MAX_VIDEO_MATRIX_LIMIT]

  included do
    LIMITS.each do |name, value|
      MediaAttachment::CustomLimits.replace_constant(self, name, value)
    end

    MediaAttachment::CustomLimits.replace_constant(
      self,
      :IMAGE_STYLES,
      MediaAttachment::CustomLimits.image_styles_with_original_pixels(const_get(:IMAGE_STYLES), IMAGE_ORIGINAL_PIXELS)
    )
  end

  class << self
    # 上流で定義済みの定数を「already initialized constant」警告を出さずに置き換える
    def replace_constant(base, name, value)
      raise NameError, "#{base}::#{name} が見つかりません。上流の変更に合わせて #{__FILE__} を更新してください" unless base.const_defined?(name, false)

      base.send(:remove_const, name)
      base.const_set(name, value)
    end

    # 上流の IMAGE_STYLES の original スタイルだけ pixels を差し替えた、凍結済みのコピーを返す
    def image_styles_with_original_pixels(styles, pixels)
      original = styles.fetch(:original).merge(pixels: pixels).freeze
      styles.merge(original: original).freeze
    end
  end
end
