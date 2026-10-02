# Same Elixir/OTP versions as .tool-versions; both stages use Alpine musl.
ARG BUILDER_IMAGE=hexpm/elixir:1.20.2-erlang-29.0.4-alpine-3.22.5
ARG RUNNER_IMAGE=alpine:3.22.5
FROM ${BUILDER_IMAGE} AS builder
RUN apk add --no-cache build-base git ca-certificates
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config/config.exs config/prod.exs config/
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
COPY priv priv
COPY assets assets
COPY config/runtime.exs config/runtime.exs
COPY rel rel
RUN mix compile --warnings-as-errors && mix assets.deploy && mix release

FROM ${RUNNER_IMAGE} AS runner
RUN apk add --no-cache libstdc++ ncurses-libs libcrypto3 libssl3 liblksctp ca-certificates \
    && addgroup -g 10001 atlas && adduser -D -u 10001 -G atlas -h /app atlas
WORKDIR /app
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 PHX_SERVER=true PORT=5000 IMAGE_STORAGE_PATH=/app/storage/meetup_images
COPY --from=builder --chown=atlas:atlas /app/_build/prod/rel/ca_tools ./
COPY --chown=atlas:atlas --chmod=755 rel/docker-entrypoint.sh /app/docker-entrypoint.sh
RUN mkdir -p /app/storage/meetup_images && chown -R atlas:atlas /app/storage
USER atlas
EXPOSE 5000
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:5000/ || exit 1
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["start"]
