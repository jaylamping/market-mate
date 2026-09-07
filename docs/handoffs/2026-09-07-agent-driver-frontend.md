# Handoff: agent driver — frontend link-up and Windows host cutover

- State: active
- Recorded at (UTC): 2026-09-07T23:30Z
- Repository commit and branch/worktree: branch `jl/agent-driver`, worktree `~/code/market-mate-driver` (see the latest commit on that branch; this file is committed with the backend work)
- Issue / PR: follow-ups [#162](https://github.com/jaylamping/market-mate/issues/162) [#163](https://github.com/jaylamping/market-mate/issues/163) [#164](https://github.com/jaylamping/market-mate/issues/164) [#165](https://github.com/jaylamping/market-mate/issues/165) [#166](https://github.com/jaylamping/market-mate/issues/166) [#167](https://github.com/jaylamping/market-mate/issues/167) [#168](https://github.com/jaylamping/market-mate/issues/168) (Windows/Tailscale host). Plan: `~/.cursor/plans/agent_driver_&_providers_34377b6c.plan.md` (local file, not repository authority).

## Objective and scope

Backend, database, and HTTP API for the agent driver are implemented and verified on this branch. Two things remain and were split by the owner into separate sessions:

1. Frontend link-up (this handoff's primary consumer): make `/agents`, `/system`, and the shared `UsageWidget` production-quality against the real driver API, then run the frontend verification profile and a browser check.
2. Windows host cutover (#168): build and run the Compose stack on the always-on Windows machine over Tailscale + SSH, then run validation scripts there. Covered in a separate handoff section below so either session can pick it up.

Out of scope: phase 2/3 agent work (#162–#167), Paper/Live execution, any new model/spend authority.

## Decisions and authorization

- Architecture: [ADR 0013](../adr/0013-agent-driver-and-generic-providers.md) (agent driver, generic `ProviderClient` adapters, quota-aware tiered routing, Cursor cloud agents as an inference provider). ADR 0005 updated for agent routes replacing `routing.json`.
- Owner approvals recorded in the originating chat (Sep 7 2026): consolidate Docker services onto one backend image; fix build performance; add Cheaper Inference and Cursor (cloud agents) as providers; move the stack to the Windows machine over Tailscale (Windows host, not a Linux VM); **local Postgres data may be wiped and re-created** — no data migration required for the host move.
- Provider credentials are entered by the owner through the `scripts/setup_*.py` scripts only. No API key belongs in Git, Compose files, logs, or this document. Approvals for models/spend remain the persisted `agent_route` / spend policy rows; catalog availability is not authorization.

## Completed and verified

Tested tree: the commit that includes this file on `jl/agent-driver` (run `git log -1` there).

- Migrations `0088_agent_driver.sql`, `0089_cheaper_inference_provider.sql`, `0090_cursor_cloud_agent_provider.sql` (all unreleased; edited in place during development, immutable once applied anywhere shared).
- `backend/src/driver/` (registry, adapter, cursor_agent, openrouter, dispatch, quota, bootstrap, api, client, log), binary `backend/src/bin/agent-driver.rs`. Old `openrouter-connector` and `cursor-connector` binaries removed; workers use `driver::client::Dispatcher`.
- Compose: single `market-mate-backend` image via the `x-backend-image` anchor; `agent-driver` service on `:8083` (internal only); secret volumes `zai-secrets`, `opencode-secrets`, `cheaper-inference-secrets`, `openrouter-secrets`, `cursor-secrets`; BuildKit cache mounts in `backend/Dockerfile` (warm backend rebuild ≈ 85–90 s on the M-series Mac).
- Verification on the tested tree (all pass):
  - `bash scripts/verify.sh context` — ok.
  - `bash scripts/verify.sh backend` — `cargo test --locked` 145 passed / 10 ignored; `cargo fmt --check` clean. Pre-existing `unused axum::Json` warnings in `market_data_connection/tests.rs` are on `main`, not this branch.
  - `npm --prefix frontend run typecheck` and `npm --prefix frontend test` — pass. `npm run build` was run by the earlier frontend subagent but not re-run after the last API change; re-run it.
  - `bash scripts/agent_driver_test.sh` — SQL probe passes (`evidence/agent-driver/probe.log`), including: unconfigured providers are skipped (`provider_not_configured`) rather than attempted; skipped routes carry `ordinal`.
  - `bash scripts/research_campaign_test.sh` — passes (worker cutover parity).
- Live smoke on a throwaway Compose project `market-mate-driver` (fresh volumes, host ports 15450/18081/18080/13000, no credentials): driver bootstrap imported 7 agents with empty routes; all six providers probe `not_configured`; `PUT /api/agents/evaluator` saved routes (revision 2); `POST /dispatch` returned `status:"held"` with both routes skipped as `provider_not_configured`; `/api/usage/summary` returned `holds:1`; `/agents` rendered the agent list and editor in the browser.

## Remaining work

### A. Frontend link-up (new session)

1. Start from `frontend/AGENTS.md`, `DESIGN.md`, `frontend/lib/agents.ts` (types + parsers + queries), `frontend/app/agents/AgentDriver.tsx`, `frontend/components/UsageWidget.tsx`, `frontend/app/system/SystemPage.tsx`, and the proxies under `frontend/app/api/{agents,providers,usage,config}/`.
2. API contract facts the parsers depend on (all verified live):
   - `GET /api/agents` → `{agents:[{id,name,spec,priority,hold_at_pct,enabled,revision,updated_at,routes:[{tier,ordinal,provider_id,model_id,share_pct}],current:{status:eligible|held|blocked, route?, held_until?, reason?, skipped?:[{provider_id,model_id,tier,ordinal,reason,next_eligible_at?}]}}]}`.
   - `PUT /api/agents/{id}` body is `{expected_revision, ...patch}` (flattened patch: `name`, `priority`, `hold_at_pct`, `enabled`, `spec`, `routes`). Response `{status:"saved",revision}` or `{status:"conflict"}`. The Next.js proxy enforces same-origin (`origin` header) and returns 403 `Invalid origin` otherwise.
   - `GET /api/providers` → `{providers:[{..., credential_state, windows:[...], state:{probe_state,cooldown_until,cooldown_reason,probe_at,last_error}}]}`; `probe_state` lives under `state`, not top level.
   - `GET /api/usage/summary` → `{holds,in_flight,observed_at,providers:[{id,display_name,kind,enabled,probe_state,cooldown_until,windows:[{window,source,percent_used,status,resets_at,observed_at,threshold_pct,pacing_slack_pct,limit_count,elapsed_pct,over_threshold,over_pace}]}]}`.
   - `GET /api/providers/{id}/models`, `/status`, `/usage`; `GET /api/config/revisions`.
   - Empty-path proxy routes must not append a trailing slash (fixed in `[[...path]]/route.ts`; keep that behavior).
3. Known UI gaps seen in the browser: the `UsageWidget` inside the agent editor wraps badly at narrow widths (provider names stack, bars shrink to nothing); the widget in `layout.tsx` footer is fine at desktop width. Agent list rows show `Held`/`blocked` as raw status text — consider the design system's status treatment. Provider editor (thresholds, pacing, enable/disable) and revision history views exist but were only exercised by unit tests, not in the browser.
4. Add/adjust tests in `frontend/tests/agents.test.tsx` and `frontend/tests/usage-widget.test.tsx` so fixtures mirror the live payload shapes above (they passed before but did not catch the missing `ordinal` on skipped routes; make the fixtures stricter).
5. Run `bash scripts/verify.sh frontend`, then a browser pass on `/agents`, `/system`, and the footer widget with the throwaway stack (`docker compose -p market-mate-driver ...` with the four `MARKET_MATE_*_PORT` variables) or the Windows host once it is up.

### B. Windows host cutover (#168)

Prerequisites on the Windows machine: Docker Desktop (WSL 2 backend, Linux containers), Git, Tailscale joined to the same tailnet, OpenSSH Server enabled (Windows optional feature) with the owner's public key in `administrators_authorized_keys` or `~/.ssh/authorized_keys`.

1. From the Mac: `ssh <user>@<windows-tailscale-name>` (Tailscale MagicDNS name; do not publish the stack on the tailnet until the host is validated).
2. On Windows (PowerShell): `git clone <repo> C:\code\market-mate && cd C:\code\market-mate && git switch jl/agent-driver` (or `main` after merge).
3. Credentials, one prompt each, entered by the owner (never pasted into chat): `python scripts/setup_zai.py`, `python scripts/setup_opencode.py`, `python scripts/setup_cheaper_inference.py`, `python scripts/setup_openrouter.py`, `python scripts/setup_cursor.py`, plus the existing Alpaca/market-data setup scripts. Each writes into its Docker volume via a `*-credentials` Compose service.
4. `docker compose build` then `docker compose up -d --wait`. Fresh `pgdata`; migrations apply on first start; driver bootstrap seeds the 7 agents with empty routes.
5. Validation on the host: `docker compose ps`; `docker compose logs agent-driver` should show `provider.probe` with `state:"connected"` for every configured provider and `quota.poll.*` samples for Z.ai / OpenCode Go / Cheaper Inference; `bash scripts/agent_driver_test.sh` and `bash scripts/research_campaign_test.sh` (run under WSL or Git Bash; both need Docker and `psql` inside the Compose Postgres); `curl http://127.0.0.1:3000/api/usage/summary`.
6. Configure agent routes in `/agents` (they start empty by design; `routing.json` import is only used when that file exists).
7. Expose over Tailscale only after validation: either `tailscale serve --bg 3000` on the Windows host (HTTPS on the tailnet) or an SSH port-forward from the Mac (`ssh -L 3000:127.0.0.1:3000 ...`). Compose binds all ports to `127.0.0.1`; keep that and let Tailscale/SSH do the exposure.

## Runtime snapshot to refresh

Snapshot at 2026-09-07T23:25Z on the Mac; verify before relying on it.

- Throwaway smoke stack: Compose project `market-mate-driver`, host ports 15450 (Postgres), 18081 (custody), 18080 (backend), 13000 (frontend); all 9 services healthy; no provider credentials; `evaluator` agent has two subscription routes (`zai`, `opencode-go` → `glm-5.3-flash`) saved as revision 2. Tear down with `docker compose -p market-mate-driver down -v` when done.
- The owner's main `market-mate` stack (default ports) was running separately and untouched.
- Local images: `market-mate-backend`, `market-mate-driver-frontend`. Nothing pushed to a registry; the Windows host builds from source.
- No provider requests were sent during verification; all dispatches were held or fixture-only.

## Working tree and pitfalls

- Everything for this task is committed on `jl/agent-driver` in `~/code/market-mate-driver`. The main checkout `~/code/market-mate` has unrelated uncommitted edits (`CONTEXT.md`, `docs/agents/verification.md`, `docs/architecture.md`, `docs/research/research-campaign.md`, `frontend/app/incubator/*`, `frontend/tests/incubator.test.tsx`, `frontend/tests/research-campaign.test.tsx`) belonging to another task; do not touch them from this branch.
- Migrations 0088–0090 are unreleased and were edited in place while iterating. Once the Windows host (or any shared database) has applied them, add new migrations instead.
- `output_limit` is strict: dispatch requests without `max_tokens` / `max_completion_tokens` / `max_output_tokens` fail with `invalid_output_limit`. Workers always send one; ad-hoc curl tests must too.
- `probe_state_for` in `driver/quota.rs` maps `credentials_unavailable` → `not_configured`; `provider_route_eligibility` skips `not_configured` and `credentials_rejected` providers with a 5-minute `next_eligible_at`.
- `POST /dispatch` field names: `key`, `agent_id`, `purpose`, `request`, `allow_paid`, `parent_attempt_id`, `model`.
- Cursor cloud-agent dispatches are long-running (up to `run_timeout_secs`, default in provider `settings`); `Dispatcher::send` timeout is 960 s. Streaming is rejected for `cursor_agent`.
- Local `vitest` in the frontend workspace needs the repo's Node version; `node --experimental-strip-types` is unavailable on this Mac's Node.
