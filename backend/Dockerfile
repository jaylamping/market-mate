FROM rust:1.85-slim AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
RUN rustup show active-toolchain
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
COPY --from=build /app/target/release/custody /usr/local/bin/custody
COPY --from=build /app/target/release/paper-connector /usr/local/bin/paper-connector
COPY --from=build /app/target/release/openrouter-connector /usr/local/bin/openrouter-connector
COPY --from=build /app/target/release/cursor-connector /usr/local/bin/cursor-connector
COPY --from=build /app/target/release/research-agent /usr/local/bin/research-agent
COPY --from=build /app/target/release/incubator-chat /usr/local/bin/incubator-chat
COPY --from=build /app/target/release/incubator-requests /usr/local/bin/incubator-requests
COPY --from=build /app/target/release/market-data-download /usr/local/bin/market-data-download
COPY --from=build /app/target/release/market-data-store /usr/local/bin/market-data-store
COPY --from=build /app/target/release/market-data-acquire /usr/local/bin/market-data-acquire
COPY --from=build /app/target/release/market-data-service /usr/local/bin/market-data-service
RUN mkdir -p /var/lib/custody /var/lib/model-policy /var/lib/market-data && chown app /var/lib/custody /var/lib/model-policy /var/lib/market-data
USER app
EXPOSE 8080
CMD ["backend"]
