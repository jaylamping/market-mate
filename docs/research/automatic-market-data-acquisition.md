# Automatic acquisition (WU-62)

Setup can now emit a structured `data_request` alongside its fixed diagnostic specification. The acquisition worker discovers waiting requests, freezes exact sessions, reuses compatible local observations, fetches missing symbol windows, validates prices with the existing momentum engine, registers the panel, and pins it in one database transaction. Existing experiment notifications wake the Setup/Experiment worker to validate the handoff, preregister, dispatch, and calculate the diagnostic.

## Supported request

```json
{
  "calendar": "XNYS_2025_2026_v1",
  "symbols": ["AAPL", "XOM", "JPM", "NEE"],
  "start": "2026-01-05",
  "end": "2026-01-08",
  "benchmark": "SPY",
  "symbol_asof": "2026-01-08",
  "cash": "zero_interest"
}
```

This is a format example, not a recommended experiment. Setup must derive the universe, dates, benchmark and cash assumption from the pinned research intent or clarification. It must ask for missing details, not substitute a default. The inclusive range includes lookback/warm-up sessions. The existing 4–32 symbols, 3–60 sessions, 120-calendar-day span, quantile and lookback limits apply. Today's New York date and later dates are rejected. Manual attachment remains supported; old tickets without a structured request are not silently reinterpreted.

## Pinned calendar

`XNYS_2025_2026_v1` supports only 2025–2026. It excludes weekends and published NYSE full-day closures, including January 9, 2025; early closes remain valid daily sessions. Its definition is immutable migration code and the calendar version is retained with every job. Unsupported years require a new version; no weekday-only fallback exists. An unexpected closure will produce missing coverage and block attachment until a calendar update/new request is supplied.

Sources checked September 7, 2026: [NYSE holiday calendar announcement](https://ir.theice.com/press/news-details/2024/NYSE-Group-Announces-2025-2026-and-2027-Holiday-and-Early-Closings-Calendar/default.aspx), [January 9 mourning closure](https://ir.theice.com/press/news-details/2024/The-New-York-Stock-Exchange-Will-Close-Markets-on-January-9-to-Honor-the-Passing-of-Former-President-Jimmy-Carter-on-National-Day-of-Mourning/default.aspx), and [NYSE hours](https://www.nyse.com/trade/hours-calendars).

## Run locally

Use an already configured WU-61 source/entitlement pair. Provision a local database login with only membership in `market_data_acquirer`; no direct price-table, binding or entitlement grants are needed. Supply the existing private Alpaca credential JSON file (mode 0600, `key_id` and `secret_key`), then run:

```sh
MARKET_DATA_DATABASE_URL='postgres://YOUR_LOCAL_ACQUISITION_LOGIN@127.0.0.1:5432/market_mate' \
MARKET_DATA_SOURCE_ID='YOUR_CONFIGURED_SOURCE_UUID' \
MARKET_DATA_CREDENTIALS_FILE='/absolute/private/path/alpaca.json' \
cargo run --locked --bin market-data-acquire
```

`--once` drains at most one job. Normal operation listens to the existing `incubator_experiment` notification channel and polls every 30 seconds for missed notifications and expired leases. Database reconnects back off five seconds. This executable is included in the backend Docker image. Source setup UI and a managed Compose service are WU-63; no production credentials or real downloads were configured by WU-62.

## Recovery and control

One job per ticket freezes the request and source. Claims serialize on the source, select jobs with row locks, and issue a random five-minute lease token. A download has a two-minute overall timeout. After a crash, another process recovers the expired lease. Only the current token may finish; a source check and current waiting/supersession check precede atomic registration and binding.

Transient network, rate-limit and provider-availability failures retry after 60 seconds. There are three acquisition attempts total, including expired leases. Permanent failures wait for explicit retry with the same request and remaining budget. Exhausted or invalid requests need a new experiment; parameters are never changed by Retry.

The local Incubator API exposes `GET /workflow/{id}/acquisition` and `POST /workflow/{id}/acquisition` with `{"action":"retry"}` or `{"action":"cancel"}`. The new UI controls follow in WU-63. Cancellation fences attachment immediately; an already in-flight, bounded download may finish but its response cannot be stored or attached. Manual binding or research supersession also blocks an outstanding acquisition's commit. Completed jobs cannot be cancelled or rebound.

## Cache and retention

Cache reuse requires the configured source, exact symbol-mapping date, and a complete requested symbol window from a single retained panel assembled on the current New York day. SIP/all-adjustments/USD are fixed by WU-61. Partial symbol coverage is fetched as a whole window so one instrument does not splice adjustment vintages. Missing whole symbols are fetched in one multi-symbol request; a complete cache hit makes no HTTP request. This conservative policy trades a few requests for reproducible adjusted series. A later-day acquisition refreshes history rather than silently carrying an older adjustment vintage forward.

Acquired envelopes mark reused-observation counts and explain that their receipt is assembly time; original observation receipts remain in the shared store. No download files are created. Exact observations retain their existing WU-61 identities and deletion behavior. Jobs and audit records contain control metadata, never provider responses or prices. Source removal makes job projections unavailable and fences in-flight commits. WU-61 deletes price payloads, derived results and managed diagnostics; external backups remain outside its cleanup claim.

## Evidence

`scripts/wu62_market_data_test.sh` uses a fresh Compose database and a loopback-only provider double. It checks Setup → waiting → acquisition → executed diagnostic, concurrent workers, complete and partial cache reuse, missing coverage before pinning, explicit retry, restart recovery, stale token rejection, cancellation, source removal, restricted database roles, calendar rules and existing storage/experiment regressions. It does not claim a credentialed real-provider smoke test, production deployment, scheduled refresh or graph functionality.
