# Architecture and implementation map

This map describes the source at its last review on 2026-09-07, based on merge `b5963db` plus campaign backlog pickup, experiment throughput, and acquisition worker timeout recovery. Runtime state must be checked separately with `python3 scripts/doctor.py --runtime`. Update this map when service ownership or authority boundaries change.

## Implemented system

The frontend is a Next.js application backed by Rust/Axum services and PostgreSQL. Container definitions, ports, credential mounts, runtime users, and service dependencies live in [docker-compose.yml](../docker-compose.yml). Rust binaries are in [backend/src/bin](../backend/src/bin); the backend entrypoint is [main.rs](../backend/src/main.rs).

| Component | Responsibility and source |
| --- | --- |
| Frontend | Supervisory pages plus explicit research/configuration controls; [app](../frontend/app), [API proxies](../frontend/app/api), [shared components](../frontend/components) |
| Backend | Health/readiness, migration validation, checkpoint/recovery services; [main.rs](../backend/src/main.rs), [migrate.rs](../backend/src/migrate.rs), [checkpoints.rs](../backend/src/checkpoints.rs) |
| PostgreSQL | Durable state machines, runtime-role restrictions, audit events, assignments, capacity receipts; [migrations](../db/migrations), [fixtures](../db/fixtures) |
| Custody | Local checkpoint custody and receipts; [custody binary](../backend/src/bin/custody.rs) |
| Incubator requests | Request intake, seed checking, Ticket Creator, evaluation, refinement, and experiment workers; [entrypoint](../backend/src/bin/incubator-requests.rs), [requests](../backend/src/incubator_requests.rs) |
| Incubator chat | Persistent research conversations and streaming; [incubator_chat.rs](../backend/src/incubator_chat.rs) |
| Market data | Source setup, acquisition, storage, and diagnostic datasets; [service entrypoint](../backend/src/bin/market-data-service.rs), [market_data.rs](../backend/src/market_data.rs), [acquisition](../backend/src/market_data_acquisition.rs) |
| OpenRouter / Cursor connectors | Provider connection and model-policy surfaces; [openrouter.rs](../backend/src/openrouter.rs), [cursor.rs](../backend/src/cursor.rs), [model_routing.rs](../backend/src/model_routing.rs) |
| Paper connector | Read-only Alpaca Paper account view; [paper.rs](../backend/src/paper.rs). This is not an order-execution service. |

## Seed request flow

Seed is the display name for the automatic ticket intake; code, SQL, routes, and ADRs keep the identifier `campaign`.

1. The Principal's saved seed settings select the creator and bound intake. [Seed controls](../backend/src/incubator_campaign.rs) and [seed SQL](../db/migrations/0074_research_campaign.sql) own the transition, with subsequent migrations replacing functions.
2. [Ticket Creator](../backend/src/incubator_ticket_creator.rs) proposes a title, premise, and supported diagnostic specification. It receives used momentum cases and occupied 10 bps buckets from seed candidates and assignment history, plus a rotating lens and literature anchors. Output is untrusted and validated in Rust and at database boundaries.
3. [Seed Check](../backend/src/incubator_requests.rs) compares the pinned assignment corpus for the same exact diagnostic case. That comparison is local. Only an exact case is a duplicate and leaves the live queue. Incomplete checks record the original result and queue a linked retry without pausing the backlog. Successful nonduplicates enter the existing research workflow. Manual assignment similarity still uses a model.
4. Research, evaluation, refinement, and [experiments](../backend/src/incubator_experiment.rs) preserve lineage. Observed market data and fixed diagnostic contracts remain separate from model-generated claims.
5. [Capacity admission](../backend/src/openrouter_capacity.rs) records each research and later-stage dispatch and its reservation/outcome. [Request adaptation](../backend/src/openrouter_request.rs) respects model capabilities without removing output or cost bounds.
6. [Recovery](../db/migrations/0079_campaign_recovery.sql), [backlog pickup](../db/migrations/0080_campaign_backlog_pickup.sql), [throughput](../db/migrations/0081_campaign_experiment_throughput.sql), [research retry](../db/migrations/0083_research_retry_campaign_paid.sql), [exact-case Check](../db/migrations/0085_campaign_exact_case_check.sql), and [free seed research](../db/migrations/0086_campaign_paid_research_authorize.sql), and [near-duplicate intake](../db/migrations/0087_campaign_near_duplicate_intake.sql) create a linked new proposal for a stopped check, drain Created cards without a claim timer, retry one unusable Experiment-agent or Research Scout reply, and let a paid campaign creator run Ticket Creator only. Research Scout uses the configured free Research runner. Original checks remain available.

Read [seed behavior](research/research-campaign.md), [capacity operation](research/openrouter-capacity-operation.md), and the relevant ADR before changing this flow. A paid seed creator authorizes Ticket Creator only. Automated Research Scout and later seed stages stay free-only while automated paid spending is off. Seed Check does not call a model. General manual/automated routing has separate policies.

## Current implementation versus planned design

- Research workers and configuration endpoints perform real writes and may incur approved model/data costs. “Zero order authority” does not mean the entire application is read-only.
- `momentum_v1` is an implemented bounded diagnostic, not general strategy qualification. Fixture acceptance does not establish observed-data performance.
- The domain terms Incubator, Engine, and Sentinel describe responsibilities and controls. Do not assume each is a separate running service; inspect the actual SQL and binaries.
- Paper/Live governance, cloud portability, and qualification documents under [research](research) include plans and policy discussions. A document or glossary entry is not evidence of a deployed execution capability.
- Provider configuration and runtime state are not in Git. A new checkout does not inherit credentials, model approvals, database contents, or container images from a previous IDE session.

## Evidence navigation

Use [verification](agents/verification.md) to select checks. Source-linked acceptance JSON lives under [evidence](../evidence); its hashes identify the tested files. Live logs and database receipts establish what actually ran. A compiled binary can embed older migration bytes, and a healthy container can still be running an older image than the local tag.
