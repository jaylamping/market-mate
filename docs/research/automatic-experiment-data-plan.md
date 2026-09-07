# Automatic market data for personal research

Date: 2026-09-07. Owner-approved implementation direction. WU-60 implements the first download unit; later units remain planned. No paid service is authorized by this plan.

## Direction

Build a small local downloader that supplies experiment tickets automatically. Start with Alpaca Basic historical daily data as the leading free technical candidate. Keep a thin provider adapter so a change of source does not require rewriting the experiment workflow. See the [source comparison](automatic-market-data-sources.md) for verified features, prices and actual restrictions.

The owner clarified that this is a personal project and wants proportional controls. Do not make enterprise compliance machinery, formal certification of every artifact class, or future Paper/Live governance prerequisites to the local prototype. Preserve practical essentials: account terms review, no unexpected charges, reliable prices, no fabricated observations, repeatable results, credentials kept private, and the ability to remove a provider's data. Explicit provider prohibitions still affect source choice; gaps in published archival terms should be described as uncertainty rather than proof of prohibition. Ask the provider only about a material ambiguity the applicable agreement does not resolve.

This is a proposed Local Research simplification of the broader CONTEXT.md policy, based on that user instruction. It does not change requirements for future trading or claim that existing entitlement enforcement can simply be bypassed. Record the narrow local-purpose configuration in existing source/entitlement structures; do not claim certifications that were not performed.

## What the user will experience

Connect a data provider once in Settings using a secret credential field. Show the provider, free/paid plan and collection scope. After that, supported tickets automatically move through:

`Waiting for market data → Downloading prices → Checking coverage → Running experiment`

Automatically reuse available local prices, fetch missing dates, validate, register the dataset and attach it. Show symbols, dates, source, freshness and any concrete error. Retry should retry acquisition, not merely refresh an empty dropdown. Keep manual attachment as an advanced option. No SQL, JSON file preparation or recurring manual downloads.

A ticket with an unclear universe or period still needs clarification; do not quietly invent a different experiment just to produce a valid panel.

## Source recommendation

Alpaca Basic is the first candidate because its free historical API supports consolidated SIP data older than 15 minutes, multi-symbol retrieval, adjustments and sufficient capacity for our tiny panels. Explicitly request SIP; the free real-time IEX feed is a different dataset. [Alpaca FAQ](https://docs.alpaca.markets/us/docs/market-data-faq), [plans](https://docs.alpaca.markets/us/v1.1/docs/about-market-data-api).

This is a technical recommendation, not a finding that every storage right has been verified. Review the actual account agreement during setup; public terms leave archival/replay permissions uncertain. No provider contact, account creation or terms acceptance was performed for this plan.

Tiingo Power is the paid alternative if needed: published pricing is $30/month or $300/year, with convenient adjusted open/close fields. Its free tier forbids durable storage, while paid storage is tied to an active subscription and deletion on cancellation/downgrade. Those are concrete reasons not to start with free Tiingo. [Pricing](https://www.tiingo.com/about/pricing), [terms](https://api.tiingo.com/tos/), [EOD schema](https://www.tiingo.com/documentation/end-of-day).

Do not buy anything yet. Other options and their drawbacks are in the source comparison.

## Small implementation, using what exists

1. **Add a typed data request.** Store the symbols/stable identities, date range, exchange calendar, benchmark, feed and adjustment choice alongside Setup's existing runner spec. Freeze the request before download. Respect the current 4–32-symbol, 3–60-session limits and lookback/quantile compatibility. If the research needs more, report that the runner cannot test it rather than shortening the plan silently.
2. **Add one Rust downloader.** Use the existing backend stack and Compose setup. Call historical daily bars with explicit feed, dates and adjustments. Handle pagination, timeouts, rate limits, retries and provider error payloads. Reuse the existing source registry, entitlement, instrument mapping and EOD ingestion interfaces where suitable. No arbitrary model-generated code or URLs, and no trading endpoints.
3. **Store once and reuse.** Keep prices in local PostgreSQL initially; this volume does not need a data lake or streaming platform. Use a provider/identity/date/adjustment/version key for observations and a durable request identity for jobs. Retry or concurrent workers must not create multiple experiment bindings. Keep original decimal precision and transformation metadata.
4. **Validate before attachment.** Check every requested stock/date, consistent adjusted open/close, duplicates, positive prices, identity/currency, benchmark coverage and runner compatibility. Never fill stock-price gaps with guessed values. The existing attachment path pins before full validation; change the automatic path to validate first so bad downloads do not ruin a ticket.
5. **Connect the existing handoff.** Register the validated Research Snapshot, atomically attach it if the ticket is still waiting, and trigger the existing worker wakeup. A restart recovers unfinished jobs. Recheck source availability/permissions before commit. Cancel stops unpinned acquisition; an existing experiment's inputs remain fixed.
6. **Add modest refresh.** Begin on demand. Then run once on weekday mornings using the exchange calendar and completed sessions, for only the symbols active research needs. Recover missed dates after downtime. Recheck the requested window when making a new panel because vendors correct history. Changed prices create a new version; they do not rewrite an old experiment.

Main code references: `backend/src/incubator_experiment.rs`, `backend/src/momentum.rs`, `frontend/app/incubator/ExperimentDetail.tsx`, and migrations 0010, 0011, 0013, 0016 and 0058. Add new migrations rather than modifying applied ones.

## Keep the results honest

Use the same adjustment convention for open and close. Preserve retrieval time: history fetched today is not proof it was available in that exact form years ago. Alpaca's symbol `asof` is identity mapping, not a time machine for historical knowledge. Daily bars also do not guarantee actual execution fills. [Historical bars API](https://docs.alpaca.markets/us/reference/stockbars).

The current runner uses cents and whole basis points; document conversion/rounding and reject invalid converted values. A higher-precision runner can follow later under a new version.

Use a same-source SPY series only when the experiment permits that benchmark proxy, and label it as an ETF comparison. It is not the official S&P 500 total-return benchmark. For the initial diagnostic, an explicitly labeled zero-interest cash assumption is reasonable if consistent with the research plan. Do not fabricate observed cash returns. A Treasury proxy can come later: the [official XML feed](https://home.treasury.gov/treasury-daily-interest-rate-xml-feed) provides yields, which need a defined conversion and timing convention before becoming daily returns.

A small panel is enough to exercise this diagnostic, not establish profitability or qualify a strategy for trading. No expansion of the runner is required merely to automate its data supply.

## Simple retention defaults

These are proposed housekeeping choices, not legal minimums. A provider's applicable restrictions take precedence for its data.

| Data | Default |
|---|---|
| Temporary download files | Delete after successful import. |
| Unused cached prices | Delete after 90 days without use; fetch again when needed. |
| Exact inputs to a saved experiment | Keep while the experiment is saved and retention remains permitted. Archiving a ticket is not deleting its evidence. |
| Deleted experiment inputs | Remove once no other saved experiment needs them. |
| Routine logs | 30 days; exclude API keys and raw provider responses. |
| Backups | Rolling 30 days only where provider deletion terms permit; show when a deletion still exists in backup. |

Keep the small experiment input panels rather than continuously downloading years of unused data. Share referenced observations across experiments. Storage cost is unlikely to be the limiting factor at this scale, but rights and replay still matter.

Add a basic source-level “remove downloaded data” operation and stop-download toggle. Track references so deleting one experiment does not break another. If inputs are removed, show that the old result can no longer be reproduced. Provider cancellation may require cleanup of snapshots and backups too; do not claim deleting the cache removes every copy.

There is one implementation issue to handle: existing snapshots/EOD rows embed source content and prevent ordinary deletion. Add a narrowly scoped, authorized source-payload removal mechanism or separate deletable payload storage, preserving permitted experiment metadata. Do not ship a purge button that only hides records or globally disable append-only protection. A full generalized compliance platform can wait; working removal for the one selected provider cannot be replaced by a cosmetic TTL.

Existing seven-year Decision Record policy is separate from the price-cache policy. Do not impose seven years on every downloaded price or overhaul decision retention as part of this feature.

## Delivery and verification

### Follow-on: local similarity research with pgvector

The owner proposed vector storage to discover insights and benefit from colocating data. Recommend PostgreSQL plus pgvector in the same local database. `docker-compose.yml` already uses `pgvector/pgvector:pg16`; this verifies image selection, not that the extension is enabled or similarity features are implemented. The earlier [storage investigation](research-evidence-storage-and-vector-retrieval-feasibility.md) also favors colocated retrieval. Check/install the extension through a new migration when implementing.

Keep exact prices in ordinary relational tables. Add derived vector tables with foreign keys to their input observations/windows or research documents. This provides transactional links, SQL date/symbol filters and one operational database. Vectors are an additional search representation, not compression or a replacement for the prices. Their storage and indexes add overhead. At this scale, use exact nearest-neighbor search first; [pgvector](https://github.com/pgvector/pgvector) supports exact search, approximate indexes and combining vector retrieval with PostgreSQL full-text search.

Two distinct uses:

- **Numerical market analogues:** represent each historical window using a fixed, versioned feature vector, such as trailing 5/20-session returns, realized volatility, drawdown and benchmark-relative return. Standardize features using only the training/history available at the query cutoff; preserve the scaler version. Start with ordinary calculated features, no embedding model or paid API. A later window-shape experiment could compare sequences of normalized daily returns. Never pass raw price CSVs through a general text embedding model and assume it preserves numeric similarity.
- **Related research:** embed the system's own research reports, hypotheses and experiment summaries using a pinned local text model, then combine semantic matching with keyword/date/instrument filters. Keep text vectors separate from numerical vectors; different representations do not share a meaningful distance scale. Model selection and licensing can be evaluated when implementing that small feature.

First user-visible experiment: “Find historical periods similar to this one and show what happened afterward.” Show matching dates/instruments, the features responsible for similarity, return distributions over a fixed future horizon, number of distinct matches and comparison against a simple baseline. Neighbor similarity is not a probability of profit or evidence of causation.

For an evaluation at time T, candidates must precede T, have completed outcome windows by T, exclude the query's own overlapping interval, and avoid counting heavily overlapping neighbors as independent observations. Features cannot contain future returns. Evaluate using chronological held-out periods; fit scaling/feature choices on earlier data, not the full dataset. Compare against a basic momentum/volatility filter and random eligible dates before claiming benefit. These checks prevent a convincing-looking historical match display from leaking the answer.

The current 60-session diagnostic panel is too small for strong historical analogue conclusions. Keep ingestion/storage capable of longer histories independently of the bounded runner, and backfill a modest multi-year range for a selected universe only when starting the analogue experiment. Account for universe selection/survivorship limitations. Do not expand the runner or download every ticker merely to prepare for vectors.

Keep numerical vectors rebuildable from retained prices and versioned calculations. Text vectors depend on retained documents and their model version. On input correction/deletion, invalidate and rebuild/remove dependent vectors; apply the same backup cleanup to them. No extra vector service subscription or remote raw-price embedding calls are needed.

Deliver in three practical increments:

1. Provider setup, typed requests, one adapter, local storage and source cleanup.
2. Automatic validation/registration/attachment, progress UI and restart-safe retries.
3. Daily active-symbol refresh and correction handling.

Then add one separate similarity pilot: numerical market analogues first, followed by research-document search if useful. Measure relevance, leakage-free held-out results and query latency before adding approximate indexes or more infrastructure.

Use isolated fixtures for meaningful tests: pagination/429, missing dates, split-adjustment consistency, duplicate jobs, restart recovery, validation before pinning and real deletion of source-bearing copies. Then, with configured credentials and suitable account terms, retrieve a small real panel and prove the ticket continues and replays from its fixed input. Verify the actual feed and absence of charges. No live credentialed fetch or application tests were run during this planning task.


## Consolidated work units: acquisition through cross-sector graph

The owner confirmed the entire direction: personal/noncommercial use, automatic acquisition, local price storage, reproducible experiments, pragmatic cleanup, and exploration of hidden cross-sector relationships. The following bounded units make the implementation reviewable. Each uses the repository WU loop; later units depend on tested earlier work. No cloud/vector subscription is needed.

### WU-60 — Historical panel download (implemented)

Deliver a reusable Alpaca daily-bars client and an executable local download command. Input is a typed request specifying symbols, exact sessions, symbol-mapping date, benchmark and diagnostic parameters. Output is one validated envelope containing the compatible momentum panel, request identity, retrieval timestamps, normalization version and source facts. Keep source facts separate from registry-generated entitlement lineage. Use explicit historical SIP, all adjustments and USD; prohibit redirects and arbitrary production origins. Credentials are read from a local secret file, never command arguments or output. The initial command requires explicit sessions; automatic exchange-calendar request generation is WU-62.

Complete all response pages, enforce bounded bytes/pages/attempts, recognize non-200 and in-band errors, wait between requests, and reject partial coverage, duplicates, unexpected symbols/dates and inconsistent bars. Preserve normalized source observations so the cents transformation is inspectable. Do not classify isolated fixtures as observed research; test transport is test-only. This unit produces data files, not a registered or auto-attached dataset. No database schema change is needed yet. Acceptance runs the real client against a local HTTP provider double, validates the resulting panel with the existing momentum engine, and verifies failure paths and credential non-disclosure. A real-provider smoke test is distinct and requires configured credentials.

### WU-61 — Local data storage and lifecycle

Depends on WU-60. Reuse source/entitlement/EOD contracts; add bounded personal-research source configuration and deletable payload references where current inline append-only data prevents cleanup. Add normalized observation/version identity, experiment dependencies, ingestion receipt and source-level cleanup. Retain referenced inputs; evict prices unused for 90 days. Preserve permitted metadata and mark replay unavailable after input removal. No counterfeit certification records or source payloads in audit JSON. Prove source cleanup removes downstream source-bearing copies without deleting unrelated saved experiments. Apply new migrations and isolated SQL probes.

### WU-62 — Automatic acquisition and experiment handoff

Depends on WU-61. Extend Setup with a structured request, generate exact sessions from a pinned exchange calendar, and add durable jobs with leases, idempotency and restart recovery. Reuse compatible observations, fetch gaps, validate before binding, register with real registry lineage and atomically pin the snapshot. Consume existing worker notification path. Retry/cancel semantics and revoked/unavailable-source handling are explicit. No silent universe/date/benchmark substitutions. End-to-end acceptance: waiting ticket becomes executed diagnostic on a valid provider double; missing coverage cannot advance; two workers and restart create one binding.

### WU-63 — Setup UI and scheduled refresh

Depends on WU-62. Provider setup uses the existing secret-boundary pattern; show only connection status. Replace jargon and empty refresh loop with download/validation progress, concrete errors, Retry and Cancel. Show source, date range, symbols, adjustment, cash/benchmark assumptions and replay availability. Daily exchange-aware refresh runs only for actively needed symbols and catches up after outages; no request-per-page paid upgrade or fallback. Verify browser flow including narrow viewport and a real entitled small-panel smoke test. Keep source API data local to the connector/database, with metadata only in model prompts.

### WU-64 — Numerical feature windows and historical evaluation

Depends on WU-61; can follow WU-63 for a simpler first delivery. Backfill a selected, explicitly versioned cross-sector universe over a modest multi-year range (initial proposal: 20–30 instruments, 5 years where available). Keep this separate from the diagnostic's 60-session input limit. Candidate sector mix: technology, financials, industrials, energy, utilities, consumer, health care and real estate. Selection is recorded before evaluating results; current-survivor selection is labeled as a limitation. Sector classifications are metadata, not a feature that forces same-sector similarity.

Compute separate versioned representations: (a) fixed-window daily returns for ordinary correlation; (b) returns residualized against the market, fitted only using past data; (c) feature vectors combining 5/20-session return, volatility, drawdown, benchmark-relative return and optionally volume features when present. Scale on historical training data only. Compute benchmark removal and factor exposures through explicit estimators with minimum sample checks; do not present residualization as proof of a causal relationship. Persist lookback dates, availability cutoff, input IDs, feature/scaler definitions and missing-data status. Keep future outcomes in a separate table/column set never included in vectors.

Acceptance includes hand-calculated examples, split consistency, missing data, constant-return variance, scaling leakage and exclusion of future/overlapping candidate periods. Compare against ordinary correlation and simple momentum/volatility filters before claiming incremental insight. Use chronological train/validation/test ranges and freeze choices before the final test. Report sample size, dependence/overlap limits and uncertainty; do not pick a distance metric using the final test outcomes.

### WU-65 — pgvector search and relationship graph

Depends on WU-64. Introduce local pgvector tables linked to source windows and exact numerical features. The existing installed-but-gated vector posture is intentionally extended for this owner-authorized, experimental Local Research feature; preserve the no-vector path and do not grant trading authority. Start with exact nearest-neighbor search, Euclidean distance on standardized features, and correlation-based baselines. Store representation version; do not compare incompatible vector types. No HNSW or separate graph database until measured need.

Provide two explicit graph modes: same-period stock relationships (one node per stock) and historical analogues (one node per stock/window). Construct bounded mutual-nearest-neighbor edges with deterministic tie handling, configurable but recorded thresholds, distance/similarity, sample size and source window IDs. Edge weight is not a probability. Keep minimum sample/variance checks; do not manufacture edges for missing or constant data. Sector coloring highlights cross-sector links, but clusters are discovered from behavior. Graph layouts are presentation only: proximity on screen does not establish additional evidence.

Expose a read-only API returning nodes, edges, filters and provenance. A historical query at T may only retrieve candidates with matured outcome horizons before T and no overlap with the query window. Limit repeated overlapping matches per instrument/interval to avoid inflated counts. Test exact results against a simple reference calculation, date filtering, isolated nodes, stable ties and deletion/correction invalidation.

### WU-66 — Interactive graph and insights

Depends on WU-65. Add a research exploration view with date/window and method controls, sector coloring, cross-sector-only filter and a readable list fallback. Clicking a node shows its features; clicking an edge shows both price/return series, ordinary correlation, market-adjusted relation, feature contributions and whether the connection persisted in later periods. Provide graph snapshots across time to explore relationships that form/break or recur in selloffs. Display source and limitations near the evidence.

For historical analogues, display forward-return distributions alongside eligible random-date and simple-filter baselines; show losses and distinct observation counts. Any lead/lag view is a separately evaluated lagged hypothesis, with temporal direction, multiple-comparison awareness and held-out persistence checks. Do not infer leadership or causation from an undirected similarity edge. Success means users can inspect an unexpected relationship and judge its evidence, even when no predictive benefit is found. Verify graph interaction and mobile list access with real browser QA.

### WU-67 — Optional research-document retrieval

Depends on WU-61 and useful retained document volume; independent of numerical graph. Select and pin a suitable local text embedding model, embed our research documents and link to canonical text. Combine full-text/date/symbol filtering with semantic search. Keep text and price-feature vector spaces separate. Evaluate against keyword-only retrieval on a small labeled query set before wiring into agent context. Correct/delete source documents and derived vectors together. No remote embedding charges or raw-price embeddings are required.

## Completion boundaries

The present implementation starts with WU-60 and does not claim WU-61–67 complete. After each merged unit, continue from its documented dependency-ready successor when requested. A credentialed live test, source setup, automatic handoff, scheduled refresh and graph UI each have distinct completion evidence; passing a mock downloader test cannot stand in for any of them.
