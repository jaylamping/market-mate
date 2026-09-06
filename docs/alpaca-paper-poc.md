# Alpaca Paper POC

Alpaca is the first Paper integration candidate. This integration is a read-only account viewer, not Qualified Paper, an execution adapter, a reconciled ledger, or Live certification. Other execution venues and market-data providers can be added independently.

## Start and connect

1. Create a free Alpaca Paper account and generate its Paper API keys.
2. From the repository root, run `docker compose up -d --build paper-connector frontend`.
3. Run `python3 scripts/setup_alpaca_paper.py` in an interactive terminal. Both key inputs are hidden. Do not paste keys in chat or put them in shell arguments.
4. Open http://localhost:3000/paper and refresh after five seconds.

The setup command sends the keys through stdin into the project-scoped `alpaca-paper-secrets` Docker volume. The credential file is mode 0600, owned by the connector's UID 10001. The running connector mounts the volume read-only. Only the setup helper mounts it writable. Credentials are not stored in the repository, image, frontend, Compose environment, or research database. Re-run setup to replace them. Deleting Compose volumes will delete the stored credentials; it can also delete research data, so do not use `down -v` for routine restarts.

## Boundary and behavior

- Separate Rust `paper-connector` process in Docker; no published host port, no database or custody mounts. Existing Local Research startup credential rejection remains unchanged.
- Fixed HTTPS destination `paper-api.alpaca.markets`. No user-configurable upstream URL, redirect following, or environment-proxy credentials forwarding.
- Four outbound GET resources: `/v2/account`, `/v2/positions`, `/v2/orders?status=all&limit=50&direction=desc&nested=false`, and `/v2/account/activities?page_size=50&direction=desc`.
- Internal `/paper/account` returns selected fields only, preserving decimal strings. It exposes no write routes. The keys themselves may carry broker-side trading permissions; the connector's implemented API is read-only.
- Snapshots are requested on page load/refresh, with a five-second in-memory request cache. No background trading, quote subscription, paid-data signup, durable ingestion, or order submission occurs.
- Any failed resource makes the whole new snapshot unavailable. Errors are generic codes, never upstream response bodies or credentials. Missing credentials never become zero balances.
- All open positions are requested. Orders and activities show at most 50 recent entries each; these are not exhaustive histories. Provider responses are separate observations, not an atomic or reconciled account view.
- Paper activity and simulated P&L stay outside Local Research qualification and Live ledgers. Paper lifecycle records may arrive after balance/position updates.
- Market Mate currently has no paper order path. Paper trades entered separately in Alpaca can appear here on refresh. A controlled order lifecycle is a subsequent implementation step.

## Verification and remaining work

Rust tests cover field projection, decimal precision, malformed data, sensitive headers, missing credentials, and absent write routes. Frontend tests reject Live/write boundary drift and malformed payloads. Real account access requires user-supplied Paper credentials and is not established by mock tests.

Before an execution POC, add durable venue observations, idempotent order admission, uncertain-outcome reconciliation, and the applicable Paper controls. Streaming and research market data are separate integrations. No subscription is required to connect the free Paper account.

Official references checked September 6, 2026:
- https://docs.alpaca.markets/us/docs/paper-trading
- https://docs.alpaca.markets/us/docs/working-with-account
- https://docs.alpaca.markets/us/reference/getallopenpositions
- https://docs.alpaca.markets/us/reference/getallorders-1
- https://docs.alpaca.markets/us/docs/account-activities
