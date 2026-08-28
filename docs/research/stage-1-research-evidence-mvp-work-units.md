# Stage 1 — Research Evidence MVP: work units and module-level acceptance criteria

Decision record for [issue #78](https://github.com/jaylamping/market-mate/issues/78) (Autonomous Options Trading Blueprint map, ticket [Research Evidence MVP module-level acceptance criteria and deployable work units](https://github.com/jaylamping/market-mate/issues/78)). It decomposes **stage 1 only** of the [staged-validation and restricted live-rollout contract](staged-validation-and-restricted-live-rollout.md) (commit 84c6fec) into bite-size deployable work units with module-level acceptance criteria. Later-stage implementation remains out of scope until that stage's checkpoint passes.

## Scope

Stage 1 runs in the **Local Research** environment with **zero order authority**. Its exit evidence, restated from the spine contract:

1. ≥1 Strategy Version passes Research qualification per #31: ≥3 disjoint chronological walk-forward evaluations + 1 sealed Release Holdout, Effective Independent Sample Size ≥30, one-sided 95% LCB ≥ cash +5 annualized percentage points net of Trading Costs, positive S&P 500 Excess Total Return where #31 makes it a hard comparator.
2. Executable Capital Feasibility assessment on the $1,000 bankroll (minimum contract units, collateral, approvals, fees, slippage, assignment exposure, total modeled Position Risk) — without weakening safety; if no option structure qualifies, the stage-4 stock-only fallback is recorded.
3. Data Contract entitlements and Source Registry coverage certified for every strategy input (#9, #11).
4. Cost model within the #41 caps ($250/month cash Operating Costs, $2,000 year one).
5. Principal go/no-go checkpoint: the five-part preregistered pack.

**Deferred to stage 2+ (prohibited in stage 1):** order paths of any kind, broker credentials, Capital/Paper Ledgers, Safety Kernel risk-state machinery, Conservative Simulation Overlay, venue certification, external IdP, sentiment pipeline, pre-open and real-time entitlements (SIP/OPRA), Options Lifecycle Engine, order-path Compliance Decisions and attestations, Slack/SMS alert channels, vector retrieval usage (extension installed but gated per #41/#57).

## Fixed decisions

- **First qualification target**: a stock-only, sentiment-free, point-in-time **earnings-direction strategy** (per #4's evidence standard). Sentiment and options evidence stay deferred unless the Principal later changes the target.
- **S&P comparator**: declared **hard** for this Strategy Version (broad-equity exposure); the harness implements cash and S&P comparators from day one.
- **Data entitlements in stage 1** (all inside the #41 caps): one licensed daily-EOD + corporate-actions source; one licensed earnings source with **as-of-dated estimate snapshots** (actuals cross-checked against SEC EDGAR; fail-closed on any estimate lacking as-of provenance); one point-in-time **historical** options-chain source (representative snapshot dates; no real-time entitlement). Vendors are selected during the connector work units via a recorded comparison against entitlement, license, and cost criteria — no vendor is pre-committed here.
- **Window minimums**: ≥10 years licensed history; ≥3 disjoint walk-forward test windows each ≥250 trading days with a purge gap between train and test; Release Holdout = most recent ≥60 trading days, sealed once, used exactly once. Exact window placement is preregistered per #42 and never tuned after results.
- **Statistical defaults pinned in the harness**: EIS = autocorrelation- and cluster-adjusted effective sample size; uncertainty = preregistered dependence-aware block bootstrap (one-sided 95%); multiplicity = Holm across the Experiment Family. Evaluation floors use the **lower of** raw independent-cluster count and EIS (#31). Overrides exist only through #42 preregistration.
- **Tech stack**: Rust backend (cargo workspace; deterministic seeded RNG; fixed toolchain), NextJS/TypeScript frontend, PostgreSQL authoritative (pgvector extension installed but **usage-gated**; the mandatory no-vector path keeps passing tests), Docker Compose local runtime. Suggested non-binding libraries: axum, sqlx, polars.
- **Strategy sandbox**: declarative DSL evaluated by deterministic engine code in stage 1; WASM modules are the escape hatch when a strategy outgrows the DSL — no re-architecture.
- **Identity**: no external IdP in stage 1; the dashboard binds to localhost only; public exposure is prohibited by the applicability appendix. Auth0 enters at stage 2 per #50.
- **Principal cadence in stage 1**: exception-driven only; the five-part go/no-go pack is the single scheduled touchpoint.

## Universal definition — Deployable Work Unit

Every work unit below is done only when **all four** hold:

1. **Merged PR on `main`** passing its own executable acceptance tests.
2. **Green bring-up** under local Docker Compose from a clean checkout.
3. **Audit events** for its material actions emitted to the append-only hash chain (WU-03).
4. **Named evidence artifact** produced and retrievable (listed per unit).

**Sizing rule**: a unit must be completable in one focused sitting (≤ ~6 focused hours including tests); anything bigger is split before it starts. Units may proceed in any topological order of their `Depends on` edges; issues are created lazily at execution time.

## Work units

### Phase 0 — Platform spine

#### WU-01 — Compose skeleton and Postgres baseline
Purpose: runnable multi-service local platform spine.
Depends on: —.
Acceptance:
- Given a clean checkout, when `docker compose up` runs, then backend, frontend, and PostgreSQL start healthy and pass readiness probes.
- Given the PostgreSQL image, when it initializes, then the pgvector extension is installed but no vector table or index exists (usage-gated).
- Given any service crash, when Compose restarts it, then state survives via named volumes.
Evidence: bring-up log + service health snapshot.

#### WU-02 — Migration tooling and schema conventions
Depends on: WU-01.
Acceptance:
- Given versioned migrations, when applied twice, then the second run is a no-op and a fresh database reaches head deterministically.
- Given the schema conventions doc, then every table carrying evidence carries source lineage, receipt time, and environment columns.
- Given an attempted out-of-order migration, then it fails closed.
Evidence: migration run manifest.

#### WU-03 — Audit event hash chain
Depends on: WU-01.
Acceptance:
- Given canonical audit events, when appended, then each links by hash to its predecessor and the chain verifies.
- Given any tampered byte in stored events, when verification runs, then the exact break point is reported.
- Given a consumer, then events are append-only — update or delete attempts fail.
Evidence: chain verification report.

#### WU-04 — Signed checkpoint receipts
Depends on: WU-03.
Acceptance:
- Given N chain events, when a checkpoint fires, then a signed receipt binds chain position, digest, and time, with keys held in custody distinct from the app identity.
- Given a restored database, when receipts replay, then restore verification must pass before service resumes.
Evidence: checkpoint receipt + restore-verification result.

#### WU-05 — Credential-free config and secret boundary
Depends on: WU-01.
Acceptance:
- Given the Local Research profile, then no broker credential of any kind is present, loadable, or referenced; a fail-closed scanner blocks startup on any credential-shaped config.
- Given any service, then logs are structured and never contain secret-shaped values.
Evidence: startup scan report (zero credentials).

### Tracer

#### WU-06 — End-to-end tracer slice
Depends on: WU-02, WU-03, WU-05.
Acceptance:
- Given 5 symbols, when the tracer runs, then inline EOD + EDGAR fetches produce one immutable Research Snapshot and one preregistered toy evaluation with a recorded result.
- Given the tracer's throwaway internals, then the snapshot, audit, and preregistration contracts it touches are the real ones.
- Given the run, then it appears on the audit chain and in the snapshot store with full lineage.
Evidence: tracer run artifact (snapshot + evaluation + chain position).

### Phase 1 — Identity and sources

#### WU-07 — Security Master schema and lifecycle
Depends on: WU-02.
Acceptance:
- Given Issuer, Security, Exchange Listing, Symbol Alias, and identifier entities, then validity intervals are enforced and no identifier is a primary key.
- Given a symbol reused by an unrelated object later, then identities remain distinct (alias history, never reuse).
- Given an identity-continuous symbol change, then it is representable as a time-bounded alias only.
Evidence: security-master fixture set + integrity tests.

#### WU-08 — Instrument mapping workflow
Depends on: WU-07.
Acceptance:
- Given a vendor identifier, when mapped, then its lifecycle is Proposed → Corroborated → Certified → Suspended/Retired and only Certified mappings are consumable downstream.
- Given conflicting provider mappings, then the mapping fails closed (no silent pick).
Evidence: mapping-state machine tests.

#### WU-09 — Corporate-action case storage
Depends on: WU-07.
Acceptance:
- Given a corporate action, then its case records the state progression Rumored → Announced → Terms Pending → Authoritatively Confirmed → Effective → Broker Reconciled → Final without erasing earlier states.
- Given effective-dated terms, then any point-in-time query returns exactly the terms known at that time.
Evidence: corporate-action case fixtures + time-travel tests.

#### WU-10 — Source Registry and Data Contract schema
Depends on: WU-02.
Acceptance:
- Given a source, then registry entry records license, permitted use, lineage rules, observation states, and correction semantics; unregistered sources cannot be referenced by any connector.
- Given a data contract, then every consumed field binds to a contract version with effective dating.
Evidence: registry + contract schemas with tests.

#### WU-11 — Entitlement certification gate
Depends on: WU-10.
Acceptance:
- Given an ingestion request against an uncertified entitlement, then the gate fails closed and records the denial.
- Given a certified entitlement with expiry, then use past expiry fails closed.
- Given any downstream consumer, then provenance (source, entitlement version, receipt time) is always attached.
Evidence: gate decision log.

#### WU-12 — EDGAR connector
Depends on: WU-11, WU-08.
Acceptance:
- Given EDGAR filings and XBRL actuals, then ingestion preserves receipt timing and source lineage and links identities via Certified mappings.
- Given any collected content, then it is stored verbatim as untrusted data — never executed or interpreted as system instructions.
Evidence: ingested corpus with lineage manifest.

#### WU-13 — Licensed EOD + corporate-actions connector
Depends on: WU-11, WU-08.
Acceptance:
- Given the selected vendor (selection recorded against license/entitlement/cost criteria), then daily OHLCV and corporate actions ingest point-in-time with entitlement-gated access.
- Given any missing or revised vendor data, then revisions are appended as new evidence, never overwritten.
Evidence: ingestion lineage manifest + vendor-selection record.

#### WU-14 — Earnings as-of estimates connector
Depends on: WU-11, WU-08.
Acceptance:
- Given consensus estimates, then every value carries an as-of timestamp; estimates lacking as-of provenance are rejected (fail-closed), never back-filled.
- Given announcement dates and actuals, then actuals reconcile against EDGAR-sourced values with disagreements surfaced.
Evidence: estimates corpus with provenance manifest.

#### WU-15 — Historical options-chain connector
Depends on: WU-11, WU-09.
Acceptance:
- Given representative snapshot dates, then chains ingest with contract terms mapped through the Security Master and Option Deliverable semantics.
- Given any real-time entitlement attempt, then it is refused (deferred to stage 2).
Evidence: chain snapshot store with lineage.

### Phase 2 — Research cycle

#### WU-16 — Immutable Snapshot and Manifest schema
Depends on: WU-02.
Acceptance:
- Given a Research Snapshot, then it is append-only: corrections create linked successors, never edits.
- Given a Research Cycle Manifest, then it indexes expected snapshots, completion and evidence states, stale intervals, and superseding deltas.
Evidence: schema + immutability tests.

#### WU-17 — Post-close cycle orchestrator
Depends on: WU-16, WU-13.
Acceptance:
- Given a trading day, then exactly one authoritative post-close cycle publishes, targeting the 90-minute deadline; a miss creates a visible stale interval, never a silent catch-up.
- Given partial source failure, then the manifest records Degraded Complete with dependency-scoped effects.
Evidence: cycle manifests for a sample of trading days.

#### WU-18 — Evidence Profiles and Obligations engine
Depends on: WU-16.
Acceptance:
- Given a Coverage Stage / Capability / decision purpose, then the engine resolves its typed Research Evidence Profile (universal, options, holding, portfolio distinct).
- Given a Not Applicable obligation, then a proved contract rule is required — no default substitutes for missing evidence.
Evidence: profile-resolution tests.

#### WU-19 — Evidence Delta computation
Depends on: WU-16.
Acceptance:
- Given a snapshot and its prior authoritative snapshot, then the delta covers additions, removals, corrections, expiry, observation-state and indicator changes, and newly blocked/restored dependencies.
- Given generated prose, then it is marked non-authoritative.
Evidence: delta fixtures.

#### WU-20 — Earnings event-driven deltas
Depends on: WU-17, WU-14.
Acceptance:
- Given an earnings event (announced date reached or 8-K detected), then an event-driven delta cycle publishes with its own manifest, linked to the parent cycle.
Evidence: event-cycle manifests.

#### WU-21 — Stale-interval and Degraded Complete semantics
Depends on: WU-17, WU-18.
Acceptance:
- Given an Incomplete/Failed cycle, then dependent scopes are blocked at their proven scope while independent scopes continue.
- Given a Degraded Complete cycle, then downstream use is restricted to dependency-compatible consumers.
Evidence: containment drill results.

### Phase 3 — Universe and indicators

#### WU-22 — Coverage Policy machinery
Depends on: WU-02.
Acceptance:
- Given #14's rules as a Coverage Policy Version, then capacity (40 target / 50 ceiling), stages, capabilities, promotion, demotion, anti-chasing replacement, and enhanced-risk gates are encoded and version-immutable.
- Given a policy version, then it cannot modify or promote itself.
Evidence: policy evaluation tests.

#### WU-23 — Discovery Pool screener
Depends on: WU-22, WU-13.
Acceptance:
- Given the investable universe, then the screener produces the versioned Discovery Pool with inexpensive screens only (no full sentiment collection).
Evidence: Discovery Pool snapshot.

#### WU-24 — Fitness scoring and first admission run
Depends on: WU-23, WU-26.
Acceptance:
- Given Discovery Pool members, then Coverage Fitness Score ranks data quality, execution feasibility, observability, diversification, and stability — nonpredictively.
- Given the first admission run, then 40 qualifying members are admitted deterministically and replayably, with Research Candidate stages and obligations active.
Evidence: first Coverage Universe version + replay artifact.

#### WU-25 — Principal-Pinned Overlay
Depends on: WU-24.
Acceptance:
- Given ≤5 Principal-Nominated Candidates, then pins receive full research without consuming system-selected capacity, each with a 30-day review date.
- Given a pin, then it cannot grant Trade Eligible status or prevent safety demotion.
Evidence: pin workflow demo record.

#### WU-26 — Indicator definition registry
Depends on: WU-02.
Acceptance:
- Given indicator definitions, then they are immutable and versioned with explicit observation states (e.g., Declared, Experimental, Retired).
- Given a definition change, then a new version is created; historical evaluations keep their definition versions.
Evidence: registry + immutability tests.

#### WU-27 — Core indicator computation set
Depends on: WU-26, WU-13.
Acceptance:
- Given only the strategy-declared inputs, then Core Indicators compute point-in-time correctly (no look-ahead — verified by as-of replay tests).
- Given any indicator used by the strategy, then its definition version binds into evaluations.
Evidence: indicator replay test report.

#### WU-28 — Experimental observation states
Depends on: WU-26.
Acceptance:
- Given an experimental indicator, then it is recorded as experimental, excluded from Core, and promotable only through #42 preregistration with its full lineage.
Evidence: experimental-indicator record.

### Phase 4 — Governance and statistics

#### WU-29 — Experiment Registry preregistration
Depends on: WU-02.
Acceptance:
- Given an experiment, then its preregistration (hypothesis, windows, estimators, budget, stopping rule, multiplicity plan) is immutable and content-addressed before any result exists.
- Given a post-hoc change, then it creates a new registration linked to the old one; the original never mutates.
Evidence: registration fixtures + immutability tests.

#### WU-30 — Sealed Release Holdout custody
Depends on: WU-29.
Acceptance:
- Given a holdout segment (most recent ≥60 trading days), then sealing is a one-time recorded ceremony producing tamper-evident custody.
- Given a second evaluation attempt against a consumed holdout, then it is refused.
Evidence: seal ceremony record.

#### WU-31 — Evidence budgets and multiplicity
Depends on: WU-29.
Acceptance:
- Given an Experiment Family, then Holm correction applies across family members by default; a different correction must be preregistered.
- Given an exhausted evidence budget, then further trials are refused (fail-closed), with the refusal recorded.
Evidence: budget/correction test report.

#### WU-32 — Strategy Version artifact and registration
Depends on: WU-29.
Acceptance:
- Given a declarative DSL spec (v1) plus its engine binding, then the Strategy Version is content-addressed, immutable, and registered with lineage to its preregistration.
- Given any mutation attempt, then a new version is created instead.
Evidence: strategy registry with fixture strategy.

#### WU-33 — Deterministic evaluation sandbox
Depends on: WU-32.
Acceptance:
- Given a Strategy Version and evidence snapshots, then the engine evaluates the DSL deterministically (same inputs → byte-identical outputs), resource-bounded, network-disabled, credential-free.
- Given any non-determinism or out-of-scope access attempt, then evaluation fails closed.
Evidence: determinism verification (double-run digest match).

#### WU-34 — Walk-forward engine
Depends on: WU-33.
Acceptance:
- Given preregistered windows, then ≥3 disjoint chronological test windows each ≥250 trading days run with a purge gap; chronological integrity is asserted (no train/test overlap, no leakage across the purge gap).
- Given window placement, then it cannot change after results exist.
Evidence: walk-forward run manifests.

#### WU-35 — EIS estimator and cluster counting
Depends on: WU-34.
Acceptance:
- Given an evaluation's observations, then economically dependent activity (shared thesis/issuer event/overlapping holding/common shock/dependent exit) collapses to one cluster; legs, partial fills, retries never inflate counts.
- Given the sample, then EIS is autocorrelation- and cluster-adjusted and every floor uses the lower of raw independent-cluster count and EIS.
Evidence: estimator test vectors.

#### WU-36 — Block-bootstrap LCB
Depends on: WU-35.
Acceptance:
- Given paired strategy-vs-comparator returns, then a preregistered block bootstrap produces a one-sided 95% LCB of net excess return; the exact method and block construction are preserved with the Strategy Version.
- Given seeded runs, then results are byte-identical across replays.
Evidence: bootstrap run artifact with seeds.

#### WU-37 — Net-of-cost research accounting
Depends on: WU-34.
Acceptance:
- Given simulated research trades, then commissions, exchange/regulatory fees, and slippage from a declared schedule attach to each simulated position before any performance is reported.
- Given missing cost inputs, then evaluation fails closed rather than assuming zero cost.
Evidence: cost-application report.

#### WU-38 — Qualification report artifact
Depends on: WU-34, WU-35, WU-36, WU-37.
Acceptance:
- Given a completed evaluation, then the report bundles strategy version, data/contract/entitlement versions, windows, seeds, cluster counts, EIS, LCBs vs cash and S&P (hard where declared), failures included, and verifies by deterministic replay.
- Given a failed evaluation, then the failure is reported with equal completeness.
Evidence: the qualification report artifact.

#### WU-39 — Incubator substrate
Depends on: WU-29, WU-11.
Acceptance:
- Given an Alpha Shot, then it records its Profit Contribution Hypothesis, budget, stopping rule, result, and failure lineage; Engine-lite admits/schedules assignments in a single research lane; Sentinel denies any non-entitled evidence use.
- Given any manager/desk/risk/compliance assignment, then Engine rejects it as nonconforming (charter invariants).
Evidence: Alpha Shot lineage records.

### Phase 5 — Feasibility, cost, dashboard, pack

#### WU-40 — Capital Feasibility Assessor core
Depends on: WU-15, WU-08.
Acceptance:
- Given point-in-time chains and fee schedules, then the assessor computes minimum contract units, collateral, approval prerequisites, and commissions/fees for defined-risk candidate structures on the $1,000 bankroll.
- Given missing inputs (fee schedule, chain snapshot, identity mapping), then it fails closed.
Evidence: feasibility computation traces.

#### WU-41 — Assignment, slippage, and Position Risk modeling
Depends on: WU-40.
Acceptance:
- Given a candidate structure, then assignment exposure, entry/exit slippage, and total modeled Position Risk use conservative valuation per #44/#5; nothing may weaken Risk Policy floors.
- Given a structure whose worst-case exceeds the bankroll's capacity, then it is rejected with the reason recorded.
Evidence: Position Risk model outputs.

#### WU-42 — Feasibility artifact and fallback determination
Depends on: WU-41.
Acceptance:
- Given completed assessments, then the Executable Capital Feasibility artifact states which structures (if any) qualify; if none, the stage-4 stock-only fallback is recorded explicitly without weakening safety.
Evidence: the Executable Capital Feasibility artifact.

#### WU-43 — Operating Cost Register and cap tracking
Depends on: WU-02.
Acceptance:
- Given any expense, then the register records payee, category, purpose, amount, timing, commitment, and envelope; reporting prominence is at least equal to profit reporting.
- Given cap approach (configurable threshold below $250/month / $2,000 year one), then a warning surfaces; exceeding a hard ceiling fails closed new spending-classified work.
Evidence: register with cap-tracking demo.

#### WU-44 — Cost model projections
Depends on: WU-43.
Acceptance:
- Given vendor quotes and usage assumptions, then projected monthly and year-one cash costs are computed and compared against caps, with escalation thresholds flagged.
- Given the stage-1 vendor set, then the cost model stays within the #41 caps or names the exact decision required to change that.
Evidence: the stage-1 cost model artifact.

#### WU-45 — Dashboard: command ledger
Depends on: WU-04.
Acceptance:
- Given the NextJS app, then it renders variant A (dense audit tape + exception rail + permanent system-truth header) from the signed audit chain, verifying checkpoints before display.
- Given a tampered chain, then the dashboard visibly distrusts the affected range.
Evidence: dashboard screenshot set.

#### WU-46 — Dashboard: stage-1 surfaces
Depends on: WU-45, WU-38, WU-44.
Acceptance:
- Given stage-1 state, then the dashboard shows the stage badge, qualification progress (windows, EIS, LCB vs floors), cost-vs-caps, snapshot browsing, and checkpoint-pack status — all display-only, read-only, localhost-bound.
- Given any attempt to expose the dashboard beyond localhost or grant it authority, then configuration refuses.
Evidence: surface walkthrough screenshots.

#### WU-47 — Restricted-Issuer screening gate
Depends on: WU-22.
Acceptance:
- Given a universe admission or research-targeting decision, then the versioned Restricted-Issuer List is screened first and matches block admission with a recorded compliance decision.
- Given a list change, then affected instruments freeze for research promotion (per #53's tighten-only default).
Evidence: screening decision log.

#### WU-48 — Compliance evidence publication
Depends on: WU-47, WU-03.
Acceptance:
- Given accepted compliance evidence, then it publishes to canonical `docs/research/` on `main` with commit provenance preserved (#55 pattern).
Evidence: published file + provenance record.

#### WU-49 — Five-part pack generator
Depends on: WU-38, WU-42, WU-44, WU-46.
Acceptance:
- Given stage-1 evidence, then the generator assembles the preregistered pack: Economic (LCBs, cost vs caps), Safety (containment/quarantine/compliance records, including explicit "none" with proof), Usability (dashboard acceptance artifacts), Maintenance (incident count, operator hours), and a safe-work-that-continues statement.
- Given any missing part, then the pack is marked incomplete rather than silently omitting the section.
Evidence: generated pack.

#### WU-50 — Stage-1 exit rehearsal
Depends on: WU-42, WU-49, WU-38.
Acceptance:
- Given the full pipeline, then an end-to-end dry run produces the complete stage-1 exit evidence set (qualified Strategy Version, feasibility artifact, certified entitlements, cost model, pack) and exercises both the go and no-go paths.
- Given the rehearsal, then the Principal checkpoint can be held entirely from produced artifacts.
Evidence: the rehearsal run record + pack.

## Stage-1 exit-evidence mapping

| Exit gate (spine contract) | Producing work units |
|---|---|
| Research-qualified Strategy Version (#31) | WU-29–WU-38 (+ WU-12/13/14, WU-27 inputs) |
| Executable Capital Feasibility ($1,000) | WU-40–WU-42 (+ WU-15 data) |
| Certified entitlements for every strategy input (#9/#11) | WU-10, WU-11, WU-12, WU-13, WU-14 |
| Cost model within #41 caps | WU-43, WU-44 |
| Principal go/no-go pack | WU-49, WU-50 (+ WU-45/46 surfaces) |

## Appendix — Stage-1 control applicability (Local Research)

**Required**: append-only audit chain + signed checkpoints (WU-03/04); credential-free boundary + startup credential scan (WU-05); entitlement certification gate (WU-11); evidence immutability and point-in-time semantics (WU-16, WU-09, WU-13); untrusted-content boundary for collected sources (WU-12); preregistration and sealed holdout custody (WU-29, WU-30); fail-closed evaluation sandbox (WU-33); cost caps and register (WU-43, WU-44); Restricted-Issuer screening (WU-47); compliance publication (WU-48); local volume backup with restore verification (via WU-04 receipts).
**Allowed but gated**: pgvector extension installed, zero usage; any vector-retrieval workflow requires explicit approval per #41.
**Prohibited**: all order paths and broker connectivity; broker credentials in any form; Paper/Live ledger construction; public dashboard exposure; real-time/SIP/OPRA data; automated vendor payments; any authority escalation.
**Deferred to stage 2+**: external IdP (#50); Conservative Simulation Overlay (#48); venue certification (#20); ledgers and reconciliation (#16); Safety Kernel risk-state machine (#46); sentiment certification (#11/#12); pre-open deltas and real-time event streams (#38); Slack/SMS alert channels (#36 — stage-1 alerting is in-app only); Options Lifecycle Engine (#33); Compliance Gate order-path decisions and attestations (#53).