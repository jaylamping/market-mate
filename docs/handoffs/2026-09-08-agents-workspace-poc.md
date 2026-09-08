# Agents workspace POC — 2026-09-08

Status: approved POC prepared for merge, not deployed. Branch `jl/agents-workspace-poc`, base `bc4ea51668a7c25f1ba2585b19475cb93161988d`; the implementation and final verification are recorded in the associated pull request. The running Windows stack on port 3100 was not changed.

## Open the result

- Isolated preview: http://127.0.0.1:3101/agents and `/integrations`.
- Header explicitly identifies the demo catalog. Provider accounts are disabled, credentials absent, API quota readings unknown. Local request counters are labeled local.
- Preview driver: loopback port 18083. Isolated PostgreSQL: loopback port 15449, database `market_mate_agents_poc`, data under `/tmp/market-mate-agents-poc-pg`. These are session-local observations, not durable deployment guarantees.
- Frontend was started with `AGENT_DRIVER_URL=http://127.0.0.1:18083 MM_POC_PREVIEW=1` and `npm --prefix frontend run dev -- --hostname 127.0.0.1 --port 3101` using bundled Node. Driver binary uses the isolated database and `AGENT_DRIVER_BIND=127.0.0.1:18083`.

## Source and decisions

[ADR-0013](../adr/0013-agent-driver-and-generic-providers.md) records the approved interaction and routing semantics and limitations. [Frontend instructions](../../frontend/AGENTS.md) record TanStack Query, Zustand, local draft, and TanStack Table v9 ownership.

[Agent workspace](../../frontend/app/agents/AgentDriver.tsx), [model drawer](../../frontend/app/agents/ModelSheet.tsx), [persona editor](../../frontend/app/agents/PersonaEditor.tsx), [provider modal](../../frontend/components/ProviderInspection.tsx), [network and catalog model](../../frontend/lib/model-workspace.ts).

Migrations 0091–0095 are additive. Do not rewrite their applied bytes: they were tested against isolated clusters. Model/provider policy writes use CAS revisions and preserve append-only request history. Persona retirement uses the enabled flag.

## Verification

[Acceptance evidence](../../evidence/agents-workspace/acceptance.json) contains tested source hashes. Standard `bash scripts/verify.sh` passed: 67 frontend tests, production build, Rust tests, context and whitespace checks. Two pre-existing Rust unused-result warnings remain. Ten unrelated database tests remain ignored by the standard suite.

A fresh isolated native PostgreSQL 14 cluster accepted migrations 1–95. Both rollback-only SQL probes passed via `DATABASE_URL=... bash scripts/agents_workspace_test.sh`. Local Docker was unavailable, so Docker acceptance wrappers and the deployment-version PostgreSQL container were not exercised. The existing driver wrapper's `driver_ --ignored` filter selects zero tests; it is not evidence of integration coverage.

Browser checks covered saving all configuration types, stale-revision draft retention, table pagination/search, drawer tabs, and 390px containment. The rail and drawer meet at the same measured 220px boundary on mobile. Existing command-ledger findings were individually recorded as standing legacy debt in [design triage](../../evidence/agents-workspace/design-triage.json); no detector suppressions were added.

## Follow-up boundaries

- Incubator workers still retain their exact model pins, built-in prompts, and response contracts. The POC stores persona instructions and model hierarchies; selecting personas in an Incubator workflow is not implemented yet.
- New paid model offerings remain disabled until maximum-cost reservation is implemented. Existing legacy paid policies are preserved.
- Model history currently covers the latest 200 driver attempts for current aliases; full-history pagination and historical alias attribution remain follow-ups.
- Balancing uses request counts, not token/cost/latency optimization. Unknown provider quota retains the driver's existing reactive 429 behavior.
- Deployment to Windows needs an explicitly scoped migration/rebuild and validation of the current runtime/approvals; no live authority was changed by this POC.
