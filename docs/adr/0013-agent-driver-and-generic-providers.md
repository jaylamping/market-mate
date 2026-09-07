# ADR-0013: One agent driver for every model provider

- Status: accepted
- Date: 2026-09-07
- Decision source: Principal grilling session on adding Z.ai GLM Coding Plan and OpenCode Go, then balancing GLM-5.3-Flash and Muse Spark 1.3 Contributor across subscriptions.
- Implementation: phase 1 implemented in the linked scope; phases 2 and 3 are tracked as follow-up issues and stated below.

## Context

Until this change the only inference path was a concrete `OpenRouter` struct in `incubator.rs` with a hardcoded URL, and provider identity was the string union `openrouter | cursor` repeated across Rust, TypeScript, and SQL. Spending, pacing, and admission lived in `openrouter_capacity_*`. Each provider had its own connector binary, Compose service, and policy volume. Adding two subscription providers with rolling quotas on that base meant tripling hardcoded branches and leaving quota-aware routing nowhere to live.

Verified provider facts at decision time:

- Z.ai GLM Coding Plan: OpenAI chat completions at `https://api.z.ai/api/coding/paas/v4/chat/completions`; models `glm-5.3`, `glm-5.3-flash`; quota at `GET https://api.z.ai/api/monitor/usage/quota/limit` (5-hour and weekly percent windows, monthly tool window); rate-limit code `1302`, overload `1305`; no `/models` endpoint for plan keys. The plan's terms restrict use to listed tools; the Principal accepted that risk for this personal project.
- OpenCode Go: base `https://opencode.ai/zen/go/v1`; `glm-5.3-flash` and `glm-5.3` on `/chat/completions`; `muse-spark-1.3-contributor` on `/responses`; catalog at `/models`; quota at `/usage` returning `{usage:{rolling,weekly,monthly:{status,percent,resetsAt}}}`; 401 bad key, 403 no Go plan. Muse Spark Contributor prompts and completions may be used by Meta for training; the Principal accepted that for every agent.
- Cheaper Inference: base `https://api.cheaperinference.com/v1`; OpenAI-compatible `/chat/completions` (also `/responses` and Anthropic `/messages`, unused); live catalog at `/models` whose entries carry an `aliases` array with the OpenRouter id; wallet-backed with no quota windows, so spend is read from `/v1/usage/daily` (`spend_usd` over the trailing 30 days); 402 `insufficient_balance`, 429 with `Retry-After`. The gateway retries transport/429/5xx once and fails over across upstreams itself.
- Cursor exposes no chat-completions API. It does expose Cloud Agents (`POST /v1/agents`), and since the API accepts a no-repo agent (omit `repos` and `env`), a run can serve a plain prompt: the terminal run's `result` is the reply, `GET /v1/agents/{id}/usage` reports tokens, and `GET /v1/models` lists ids. Migration 0090 registers `cursor` as `subscription`/`cursor_agent`. Cost: minutes of latency per call and one VM per request, so it belongs in later tiers, and no streaming. Cursor publishes no plan-quota endpoint; pacing is local request counts (`daily`, `monthly`) and 429 replies still cool the provider down.
- OpenRouter free models have no usage API; their 1000/day and 20/minute limits are enforced only by local counting.

## Decision

One `agent-driver` service owns every provider call. Workers submit a dispatch intent and read the recorded outcome; they never hold credentials or choose a provider.

1. **Provider registry in Postgres.** `provider` rows describe protocol (`openai_chat`, `openai_responses`, `cursor_agent`), base URL, credential path, catalog source (`live` or `static`), usage URL, and kind (`subscription`, `free`, `paid`, `catalog_only`). OpenRouter is registered twice, `openrouter-free` and `openrouter-paid`, sharing one credential file, so free capacity is routed like a subscription and paid spend stays a distinct gated tier. Seeded providers: `zai`, `opencode-go`, `openrouter-free`, `openrouter-paid`, `cheaper-inference` (migration 0089), `cursor` (routable via cloud agents since migration 0090). Wallet-backed providers without quota windows (`cheaper-inference`) carry a persisted `settings.monthly_budget_usd`; the poller converts reported spend into a `monthly` window percentage, so the same threshold/hold logic caps spend. No budget means no sample and therefore no paid admission.
2. **Provider windows and usage samples.** `provider_window` holds each provider's `rolling_5h`, `weekly`, `monthly`, `daily`, or `minute` window with its source (`api` or `local`), threshold percent (default 95), and pacing slack. `provider_usage_sample` is an append-only record of every usage poll or local recount. The driver polls usage APIs every 5 minutes and immediately after any 429, `1302`, or `1305`; local windows are recounted from `dispatch_attempt`.
3. **Agents replace roles.** `agent` rows carry the spec (system prompt, response contract, tags such as `unconstrained`, tool allowlist, iteration and tool caps), `priority`, and `hold_at_pct`. `agent_route` rows bind an agent to ordered `(provider, model)` routes in tiers `subscription`, `free`, `paid`, with a soft `share_pct` of each provider window. The seven existing dispatchers are the phase 1 agents: `research_scout`, `ticket_creator`, `similarity`, `evaluator`, `refiner`, `experiment`, `owner_chat`.
4. **Routing rule.** For each tier in order and each route by ordinal, a route is eligible only when every window of its provider is under threshold, under pacing (`used% <= elapsed% + slack%`), not in cooldown, and the agent's share is not exhausted. The first eligible route wins. If none is eligible the intent is `held` until the earliest `resets_at`. Because eligibility is recomputed per dispatch, an earlier route resumes as soon as its window resets. Automated paid routes still require the existing spending policy to allow paid dispatch.
5. **OpenRouter admission stays authoritative for OpenRouter.** Inside the driver, routes on `openrouter-free` and `openrouter-paid` are admitted through the existing `try_openrouter_capacity` functions so campaign paid-creator authorization, reservations, and paid caps from ADR-0005 and ADR-0010 keep their exact semantics. The tier walk decides whether OpenRouter is tried; OpenRouter SQL decides whether that dispatch is allowed to spend. Subscription providers are admitted by `admit_dispatch`.
6. **Outcome classes are unchanged.** Transport failure after send, HTTP 5xx, unparseable success bodies, cancellation while in flight, and any unexpected charge on a free route stay `indeterminate` per ADR-0003. Explicit rejections (4xx) are `failed`. Every attempt has an id, a `parent_attempt_id` when it is a retry or fallback, and the route used, per ADR-0004.
7. **Configuration is revisioned in the database.** `config_revision` records every provider, window, agent, or route change with source `import`, `ui`, or `api`. On first start with no agents, the driver imports `/var/lib/model-policy/routing.json` and `openrouter_capacity_control.policy` as revision 1 with source `import`.
8. **One service, no per-provider connectors.** `openrouter-connector` and `cursor-connector` are removed. The driver serves status, catalog, usage, provider, agent, and dispatch endpoints. Credentials stay in per-provider Docker volumes at `/var/lib/<provider>/credentials.json`.

### Driver HTTP contract

| Method and path | Purpose |
| --- | --- |
| `GET /healthz` | Liveness |
| `POST /dispatch` | Body `{agent, purpose, key, request, parent_attempt_id?, allow_paid?}`. Returns `{intent_id, state}` where state is `admitted`, `held`, `dispatched`, or `blocked`. Idempotent on `key`. |
| `GET /dispatch/{intent_id}` | `{intent_id, state, route, attempt_id, held_until, outcome}`; `outcome.state` is `completed`, `failed`, or `indeterminate` once terminal, with `outcome.detail` carrying the bounded provider response and classification reason. |
| `GET /providers` | Provider rows with windows, latest usage sample, and credential state |
| `PUT /providers/{id}` | `{expected_revision, enabled?, windows?}`; windows carry `threshold_pct` and `pacing_slack_pct` |
| `GET /providers/{id}/models` | Live or static catalog |
| `GET /providers/{id}/status` | Credential probe result (`connected`, `not_configured`, `credentials_rejected`, `no_plan`, `provider_unavailable`) |
| `GET /providers/{id}/usage` | Latest sample per window |
| `GET /agents` | Agents with routes and the currently eligible route |
| `PUT /agents/{id}` | `{expected_revision, spec?, priority?, hold_at_pct?, enabled?, routes?}` |
| `GET /usage/summary` | Compact per-provider window percents, `resets_at`, and current hold count for the always-on widget |
| `GET /config/revisions` | Recent `config_revision` rows |

Write endpoints accept only same-origin browser requests through the frontend proxy, as the connectors did.

## Alternatives and consequences

Duplicating the OpenRouter struct per provider would have preserved today's shape at the cost of three copies of admission and no place for balancing. A local gateway such as LiteLLM would have moved routing outside the audit and indeterminate-outcome controls. Keeping OpenRouter on its own path in phase 1 was proposed and rejected by the Principal; the compromise is that the driver fronts OpenRouter while OpenRouter's SQL still decides spend. Undocumented quota endpoints (Z.ai) may change; the poller fails soft by marking a window `unknown`, and the router then falls back to local counters plus reactive 429 handling.

## Phases

- Phase 1 (this change): registry, windows, agents, routes, driver service, chat and responses adapters, quota poller, tiered routing, worker cutover, usage widget, agents page, connector removal.
- Phase 2: Research Scout ensemble (three drafts across providers plus a Judge on a different route), Experiment/Stress Tester and Unconstrained Strategist as agents with quarantine of `unconstrained` output from Engine and Sentinel paths, deterministic orchestrator.
- Phase 3: tool loop with a named read-only SQL query catalog, Explorer/DB Guru and Legal/Compliance Reviewer agents, Anthropic Messages adapter.

## Verification

`backend/src/driver`, [schema](../../db/migrations/0088_agent_driver.sql), [probe](../../db/fixtures/agent_driver_probe.sql), [frontend agents](../../frontend/app/agents), [usage widget](../../frontend/components/UsageWidget.tsx). Run `bash scripts/agent_driver_test.sh`, `bash scripts/research_campaign_test.sh`, and `bash scripts/verify.sh`.

## Reconsider when

A provider publishes a documented usage API that replaces an undocumented one, Cursor ships a chat-completions endpoint or a plan-quota API, or the Principal changes the accepted terms for Z.ai or Contributor-tier data use.
