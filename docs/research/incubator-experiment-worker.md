# Automatic experiment worker

The `incubator-requests` service runs Setup and Experiment roles for Local Research tickets. PostgreSQL notifications wake it after ticket creation, data attachment or input. Startup and a 60-second scan recover missed notifications. A session advisory lock serializes workers; model intents are committed before outbound calls. Interrupted model calls become indeterminate and are never replayed. A recorded local execution can restart because it uses a fixed spec and immutable input with no external effects.

Setup can ask the original research model one question, then accept one owner answer. The one owner response is shared by Setup and Experiment; a post-handoff answer returns to Experiment without changing the registered spec. At most three Setup calls, one research clarification and two Experiment calls are permitted per ticket. Each call uses existing provider order and zero-spend enforcement. Setup and Experiment use their role preferences, falling back to Default. Original research clarification uses the assignment's explicit model. No raw price observations are sent to models.

A ready Setup reply with no dataset becomes **Awaiting data**. In the experiment Report tab, attach an explicitly registered `incubator_momentum_daily_v1` Research Snapshot. The worker validates its schema and coverage, preregisters the exact diagnostic spec, and asks Experiment to accept that package. Experiment can request input or execute the fixed runner; it cannot change parameters or generate executable code. A pinned snapshot cannot be replaced. Corrected data or research requires a new experiment ticket; the old record remains.

The Report tab shows executed calculations and limitations. Chat records the Setup question, original research answer, owner input and Experiment disposition. All lifecycle changes use the page-level SSE feed, including when no modal is open.

## Dataset contract

A registered snapshot payload contains exactly:

- `dataset_class`: `observed` or `fixture`. Fixtures are only for isolated acceptance; never label them observed.
- `symbols`: 4–32 unique uppercase identifiers, at most 16 characters each.
- `sessions`: 3–60 ascending unique ISO dates.
- `series`: one object per symbol, with `symbol` and `bars`.
- `benchmark`: one bar per session.
- `cash_bps`: one integer per session, between -1000 and 1000.

Each bar contains `session`, `open_cents`, `close_cents`; both prices are positive integers at most 1,000,000,000. Every series and benchmark must cover every listed session in order. Prices must already have consistent adjustments and point-in-time provenance; the diagnostic does not certify those properties. Register real data through the existing `append_research_snapshot(kind,payload,source_lineage,NULL,NULL)` ingestion boundary using valid source and entitlement lineage, then attach its returned ID. The worker does not download or manufacture data.

The `momentum_v1` spec fixes `lookback_sessions` (1–5), `quantile_count` (2–10, dividing the symbol count), `one_way_cost_bps` (0–100), and `borrow_bps_per_session` (0–100). Ranking uses closes through the signal date, with next-session open entry and close exit. Equal long/short weights sum to one gross exposure. A separate optimistic close reference is labeled as such. Costs assume a full daily close/reopen and conservatively round half-exposure borrow costs up to a whole basis point.

Outputs are diagnostic integer-basis-point means, not compounded returns, statistical significance, evidence of profitability, or strategy qualification. No order authority exists in this path.

## Verification and deployment

Run `bash scripts/incubator_experiment_test.sh` for isolated SQL, two-worker notification pickup, role handoff, dataset HTTP attachment, SSE and restart checks. Run `bash scripts/incubator_evaluation_test.sh` for the upstream regression path. Neither script inserts synthetic data into the normal project.

Migration 0058 must be applied before starting the new request worker. Rebuild all role-routing consumers together (`backend`, `openrouter-connector`, `cursor-connector`, `research-agent`, `incubator-chat`, `incubator-requests`) and the frontend. Older binaries reject the new optional routing fields. Preserve the saved routing selections.
