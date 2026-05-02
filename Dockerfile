ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5
ARG BUILDER_ALPINE_VERSION=3.21.7
ARG RUNNER_ALPINE_VERSION=3.21

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-alpine-${BUILDER_ALPINE_VERSION}"
ARG RUNNER_IMAGE="alpine:${RUNNER_ALPINE_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apk add --no-cache build-base git

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib

RUN mix compile

COPY config/runtime.exs config/

RUN mix release

FROM ${RUNNER_IMAGE} AS runner

RUN apk add --no-cache libstdc++ openssl ncurses-libs ca-certificates libgcc \
    && addgroup -S app && adduser -S -G app app

ENV LANG=C.UTF-8 \
    HOME=/app \
    MIX_ENV="prod" \
    PHX_SERVER="true" \
    PORT="4000" \
    HEX_MIRROR_TARBALL_PATH="/data/tarballs"

WORKDIR /app
RUN mkdir -p /data/tarballs && chown -R app:app /app /data

COPY --from=builder --chown=app:app /app/_build/prod/rel/hex_mirror ./

USER app

EXPOSE 4000

CMD ["/app/bin/hex_mirror", "start"]
