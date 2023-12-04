FROM ruby:3.0-bullseye

# Install Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_16.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create the mastodon user
ARG UID=991
ARG GID=991
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update && \
    echo "Etc/UTC" > /etc/localtime && \
    apt-get install -y --no-install-recommends whois wget && \
    addgroup --gid $GID mastodon && \
    useradd -m -u $UID -g $GID -d /opt/mastodon mastodon && \
    echo "mastodon:$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24 | mkpasswd -s -m sha-256)" | chpasswd && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install mastodon build / runtime deps
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
RUN apt-get update && \
    apt-get -y --no-install-recommends install \
    git libicu-dev libidn11-dev \
    libpq-dev libprotobuf-dev protobuf-compiler shared-mime-info \
    libssl1.1 libpq5 imagemagick ffmpeg libjemalloc2 libyaml-0-2 \
    file ca-certificates tzdata libreadline8 gcc tini apt-utils && \
    ln -s /opt/mastodon /mastodon && \
    gem install bundler && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Enable jemalloc
RUN ln -nfs /usr/lib/$(uname -m)-linux-gnu /usr/lib/linux-gnu
ENV LD_PRELOAD=${LD_PRELOAD}:/usr/lib/linux-gnu/libjemalloc.so.2

# Build mastodon, and set permissions
COPY --chown=mastodon:mastodon . /opt/mastodon
RUN npm install -g npm@latest && \
    npm install -g yarn && \
    gem install bundler && \
    apt-get update && \
    apt-get install -y --no-install-recommends && \
    cd /opt/mastodon && \
    bundle config set --local deployment 'true' && \
    bundle config set --local without 'development test' && \
    bundle config set silence_root_warning true && \
    bundle install -j"$(nproc)" && \
    yarn install --pure-lockfile && \
    chown -R mastodon:mastodon /opt/mastodon && \
    npm cache clean --force && \
    yarn cache clean && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Run mastodon services in prod mode
ENV RAILS_ENV="production"
ENV NODE_ENV="production"

# Use those args to specify your own version flags & suffixes
ARG MASTODON_VERSION_PRERELEASE=""
ARG MASTODON_VERSION_METADATA=""

ARG UID="991"
ARG GID="991"

COPY --link --from=ruby /opt/ruby /opt/ruby

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND="noninteractive" \
    PATH="${PATH}:/opt/ruby/bin:/opt/mastodon/bin"

# Ignoring these here since we don't want to pin any versions and the Debian image removes apt-get content after use
# hadolint ignore=DL3008,DL3009
RUN apt-get update && \
    echo "Etc/UTC" > /etc/localtime && \
    groupadd -g "${GID}" mastodon && \
    useradd -l -u "$UID" -g "${GID}" -m -d /opt/mastodon mastodon && \
    apt-get -y --no-install-recommends install whois \
        wget \
        procps \
        libssl3 \
        libpq5 \
        imagemagick \
        ffmpeg \
        libjemalloc2 \
        libicu72 \
        libidn12 \
        libyaml-0-2 \
        file \
        ca-certificates \
        tzdata \
        libreadline8 \
        tini && \
    ln -s /opt/mastodon /mastodon

# Note: no, cleaning here since Debian does this automatically
# See the file /etc/apt/apt.conf.d/docker-clean within the Docker image's filesystem

COPY --chown=mastodon:mastodon . /opt/mastodon
COPY --chown=mastodon:mastodon --from=build /opt/mastodon /opt/mastodon

ENV RAILS_ENV="production" \
    NODE_ENV="production" \
    RAILS_SERVE_STATIC_FILES="true" \
    BIND="0.0.0.0" \
    MASTODON_VERSION_PRERELEASE="${MASTODON_VERSION_PRERELEASE}" \
    MASTODON_VERSION_METADATA="${MASTODON_VERSION_METADATA}"

# Set the run user
USER mastodon

# Precompile assets
RUN OTP_SECRET=precompile_placeholder SECRET_KEY_BASE=precompile_placeholder rails assets:precompile

# Set the work dir and the container entry point
WORKDIR /opt/mastodon
ENTRYPOINT ["/usr/bin/tini", "--"]
EXPOSE 3000 4000
