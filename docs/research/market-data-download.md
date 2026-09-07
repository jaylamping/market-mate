# WU-60: local historical panel downloader

First implementation unit of the [automatic data and similarity plan](automatic-experiment-data-plan.md). Downloads a complete, validated daily panel from Alpaca's historical SIP API. It does not register snapshots, attach tickets, run a scheduled job, or create vector graphs; those are subsequent units.

## Run

Build with `cargo build --locked --bin market-data-download`. Set `MARKET_DATA_CREDENTIALS_FILE` to a private local JSON file containing `key_id` and `secret_key` for your intended Alpaca account. The file must be a regular file and owner-private on Unix (for example mode 0600). Do not put credentials or provider data in Git. The downloader holds its own credentials and only calls the fixed market-data endpoint; it does not relax the main backend's credential scanner or read trading endpoints.

Use `docs/research/market-data-download-request.example.json` as the request shape. Those dates and symbols are an illustrative request, not a dataset, an automatically selected universe, or the first ticket's research requirements. Replace them to match the intended experiment. Every trading session in the requested interval must be explicitly listed for this first unit; automatic exchange-calendar generation comes in WU-62. Holidays omitted by the source are not synthesized. All requested sessions must precede today's New York date. The exact date range is bounded to 120 calendar days and 3–60 sessions.

```
cargo run --locked --bin market-data-download -- request.json .scratch/panel-download.json
```

The parent output directory must exist. The command refuses to overwrite a file, writes owner-private output atomically, and emits only a static success/error status. It has no configurable production URL and will not follow redirects. The secret-file environment variable applies only to this command; do not add it to the credential-free backend environment.

## Output and limits

The envelope contains `panel` in the existing momentum dataset shape, the typed request/spec, a SHA-256 over the serde JSON panel bytes, a separate request digest, source observations limited to timestamp/OHLC/volume, and `source_facts`. These digests identify this encoding and are not the PostgreSQL JSONB payload digest used at registration. Source facts are not Data Entitlement certification or SQL `source_lineage`; registration must add real source/entitlement identities in WU-61/62. No test fixture is installed in the normal database.

Explicit parameters: `feed=sip`, `timeframe=1Day`, `adjustment=all`, `currency=USD`, and a frozen symbol-mapping `asof`. API documentation: [Alpaca historical bars](https://docs.alpaca.markets/us/reference/stockbars). A symbol mapping date does not establish historical knowledge availability; output is labeled retrospective. Normalization checks New York midnight timestamps, positive/OHLC-consistent prices and complete exact coverage. It rejects duplicates/unexpected observations and prices exceeding six decimal places or the runner's bounds. Prices are rounded half up to cents for the diagnostic; the parsed provider OHLC fields remain alongside them for inspection. Cash is explicitly assumed zero-interest. SPY is a declared benchmark proxy in the example, not the official S&P 500 total-return index.

The client waits 350ms before each request, follows at most 64 pages, limits each response to 2MB and attempts each request at most four times. It handles `Retry-After` up to 60 seconds, otherwise returns a retryable quota status without sleeping for hours. Transport failures while receiving a body currently fail the whole attempt; rerunning the command is safe because incomplete output is never published. The current rate limiter is per client: do not launch concurrent downloads against one account until the shared WU-62 scheduler exists. No subscription upgrade or paid fallback occurs.

A complete download is checked through the existing deterministic momentum parser and evaluator before saving, but no result is published as an executed experiment. Synthetic HTTP responses are confined to tests. A successful mock test is not a credentialed Alpaca smoke test.

## Acceptance

Run `bash scripts/wu60_market_data_test.sh`. It uses an isolated Compose PostgreSQL project, applies current migrations, exercises the actual HTTP client against an in-process local provider double, checks output publication and CLI errors, and records JSON evidence under `evidence/wu-60`. No credentials or live provider are needed. Complete the normal Rust/frontend checks as well before publication.
