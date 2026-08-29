FROM rust:1.85-slim AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY backend ./backend
COPY db/migrations ./db/migrations
WORKDIR /app/backend
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home /nonexistent --shell /usr/sbin/nologin app
COPY --from=build /app/target/release/backend /usr/local/bin/backend
USER app
EXPOSE 8080
CMD ["backend"]
