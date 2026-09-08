# syntax=docker/dockerfile:1.7
FROM rust:1.85-slim AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
RUN rustup show active-toolchain
COPY backend ./backend
COPY db/migrations ./db/migrations
WORKDIR /app/backend
# Registry, git, and target caches persist across builds so a source edit recompiles only this crate.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target,sharing=locked \
    cargo build --release --locked \
    && mkdir -p /out \
    && for bin in backend custody paper-connector agent-driver research-agent incubator-chat incubator-requests \
        market-data-download market-data-store market-data-acquire market-data-service; do \
        cp "/app/target/release/$bin" /out/; \
    done

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home /nonexistent --shell /usr/sbin/nologin app
COPY --from=build /out/ /usr/local/bin/
RUN mkdir -p /var/lib/custody /var/lib/model-policy /var/lib/market-data && chown app /var/lib/custody /var/lib/model-policy /var/lib/market-data
USER app
EXPOSE 8080
CMD ["backend"]
