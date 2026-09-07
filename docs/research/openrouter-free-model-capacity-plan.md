# OpenRouter free-model research capacity plan

Created: 2026-09-07

Status: proposed operating plan; no scheduler or live research campaign activated. Grounded in local commit `76fc2ea` and provider documentation checked on this date.

## Objective and scope

Use almost all available free inference capacity for useful Local Research and experimentation, without exceeding provider limits or generating retry storms. Supplement it with a selected cheap open-weight paid model only under the explicit free-first fallback policy below. The owner reports having purchased 10 credits, confirms Market Mate is the account's only user, and requests paid fallback selection for 429 recovery. These are sufficient planning inputs; no account purchase history or credentials were inspected.

Recommended steady operation: **980–995 accounted free attempts per day when useful work is available**, with **1,000 as the absolute free-attempt ceiling**. Dispatch independent queued free work at approximately **19.35 requests/minute during bursts**, then pace or pause according to the remaining daily allocation. Free capacity is an upper bound, not an obligation to manufacture work. Paid overflow has separate, much smaller limits.

This plan covers account-wide inference admission, research scheduling, experiment allocation, free-first paid fallback, error handling, observation, and staged rollout. It does not initiate experiments, change saved model selections, activate spending, or modify trading behavior. Research Budget, Testing Budget, and Control Capacity Reserve retain their distinct meanings in `CONTEXT.md`. Paid budget amounts below are proposed settings; the owner has requested the capability but has not selected a dollar ceiling.

## 1. Provider contract and uncertainties

| Item | Working contract |
|---|---|
| Eligibility | At least 10 credits purchased over the account's lifetime qualifies for 1,000 free-model requests/day. |
| Minute ceiling | 20 requests/minute for free variants. |
| Scope | Apply one shared account pool to all free-model calls; do not multiply capacity by keys, workers, or selected models. |
| Failures | Failed attempts consume daily quota; count them locally. |
| Capacity | Individual providers can reject requests below the platform ceiling. |
| Quota observation | Successful inference responses do not supply rate-limit headers; platform 429 responses supply limit metadata. |

Sources: [OpenRouter limits](https://openrouter.ai/docs/api_reference/limits#rate-limits), including its [Markdown source](https://openrouter.ai/docs/api_reference/limits.md) for rendered numeric constants; [OpenRouter support on failed attempts and purchase eligibility](https://openrouter.zendesk.com/hc/en-us/articles/39501163636379-OpenRouter-Rate-Limits-What-You-Need-to-Know). The support article's summary uses “> $10”; its detailed explanation and the current limits page specify at least 10. Use the current page's inclusive threshold.

The following are deliberately local policy choices, not claims about undocumented provider behavior:

- Use a conservative shared ceiling even where model/provider capacity differs. Switching an approved free model may improve availability; it does not grant a fresh daily allocation.
- The linked limits page does not establish the free-request reset timezone or exact minute-window algorithm. UTC credit-usage fields and a key's spending-cap reset are not proof of the free-request reset schedule.
- Start with a rolling 24-hour request guard. Move to the provider's daily window only after its semantics are established from authoritative documentation or credible account-specific response evidence. Display which mode is active.
- The documented key response exposes monetary usage, not an authoritative free-request counter. Never derive requests remaining from `usage_daily`, `limit_remaining`, or deprecated `rate_limit`. See the existing distinction in `docs/research/openrouter-key-limits.md`.
- Count every possibly transmitted inference attempt, including interrupted responses and malformed output. Only work definitively canceled before dispatch commitment can return its request allocation. Metadata GETs have a separate cached/paced path and are not classified as free generation attempts.

## 2. Throughput arithmetic

| Operating pattern | Average dispatch rate | Time/capacity consequence |
|---|---:|---|
| Provider ceiling | 20/minute | 1,000 attempts in approximately 50 minutes |
| Initial paced burst | One start every 3.2 seconds; 18.75/minute | Approximately 53.3 minutes for 1,000 |
| Tuned paced burst | One start every 3.1 seconds; 19.35/minute | Approximately 51.7 minutes for 1,000 |
| Spread 1,000 over 8 hours | 2.083/minute | One every 28.8 seconds on average |
| Spread 1,000 over 24 hours | 0.694/minute | One every 86.4 seconds on average |

These are dispatch calculations, not promises of completed responses. Failed calls reduce useful output. For example, a 95% accepted-output rate converts 1,000 attempts into approximately 950 accepted outputs before accounting for which outputs advance research.

Concurrency is a separate bottleneck. Sustaining 19.35 starts/minute requires roughly `ceil(19.35 × mean response seconds / 60)` requests in flight: 10 at 30-second latency, 20 at 60 seconds, or 39 at 120 seconds. A single serial researcher cannot achieve that rate when each response takes tens of seconds. Do not weaken current per-run exclusion or uncertain-outcome handling just to improve utilization.

## 3. One durable admission point

Use the existing Rust/PostgreSQL stack. Introduce one shared admission component and persistent account ledger, called by every inference path immediately before outbound dispatch. A separate Redis deployment or external queue is unnecessary at this scale.

Required accounting fields:

- Stable account-budget identity, independent of API-key rotation; policy version and quota-window mode.
- Unique attempt identity, parent work/revision/phase, request fingerprint, model, free/paid class, and purpose.
- Enqueue time, earliest dispatch time, dispatch commitment, outcome, actual usage when reported, and bounded provider-limit observations.
- Work allocation reserved, attempts consumed, attempts remaining, and any release/cancellation reason.

Admission must atomically check the global daily counter, minute window, next start time, work-specific allowance, cooldown, policy eligibility, and available in-flight slot. Concurrent workers cannot each see the same remaining slot and both send. Database time supplies the shared clock; forward/backward clock anomalies pause admission until the timing state is trustworthy.

Record dispatch commitment and the existing workflow intent in one transaction where practical. Never hold a database transaction open during network I/O. Waiting for quota occurs before the workflow becomes dispatched; queue waiting must not start the existing provider timeout or be misclassified as an orphaned request.

**A reservation for later is not permission to send later without rechecking.** The final dispatcher validates timing immediately before send. Expired send opportunities are re-admitted rather than released together after a process pause. A committed attempt that might have sent is never automatically replayed. On restart, preserve daily consumption, cooldowns, and uncertain outcomes; do not initialize a new full allowance.

At initial installation, seed the last 24 hours from existing dispatch-intent records across all consumers. Include failures and unresolved intents. If coverage cannot be demonstrated, conservatively withhold the unknown portion until it ages out; a fresh scheduler is not evidence of a fresh provider allowance.

The resulting counter is **Market Mate-accounted attempts**, not a provider-certified balance. Account exclusivity makes it useful for admission. If another application starts using this account later, bring it through the same admission path or establish a bounded allocation before continuing near the ceiling.

## 4. Pacing and daily allocation

### Minute admission

1. Begin at a 3.2-second minimum interval between starts, with a hard maximum of 20 commitments in any rolling 61-second window.
2. After a clean calibration period, use 3.1 seconds while retaining the rolling-window guard. This targets 96.8% of the nominal minute rate without relying on an exact three-second boundary.
3. Do not accumulate burst tokens during idle time. Every resumed request observes the current spacing and rolling window.
4. Provider cooldowns and more restrictive observed limits override these settings. Network arrival jitter can still cause 429s; pacing reduces that risk rather than guaranteeing remote acceptance.

### Default daily allocation

| Purpose | Initial attempts | Use |
|---|---:|---|
| Discovery | 600 | Hypotheses, comparison, focused refinement; 120 of these form the existing 20% discovery Wildcard Sleeve |
| Skeptical challenge | 150 | Disconfirmation, missing assumptions, competing explanations |
| Experiment preparation and evaluation | 150 | Clarification, runner-compatible specifications, result interpretation and reproduction planning |
| Owner interaction and bounded recovery | 80 | Chat, explicitly eligible retries/fallbacks, useful interrupted-work follow-up |
| Discretionary headroom | 20 | Release up to 15 to useful work after checking outstanding commitments; retain five as the default cushion |
| **Total** | **1,000** | All categories share the same hard ceiling |

These are proposed request allocations, not a new Research Posture Allocation or independent-evaluation certification. Apply existing posture proportions inside applicable discovery work, and preserve separately protected evaluation/compute capacity. The 20-request headroom is not the Control Capacity Reserve and cannot replace it.

Category shares are flexible within the approved total: give unused discovery capacity to work that can finish or validate existing experiments. Prioritize owner requests, eligible continuations, and evidence-producing work over starting more hypotheses. Allocate the next available paced slot fairly; priority never bypasses the minute or daily guards.

Use two scheduling modes within this one account policy:

- **Paced research, default:** distribute the usable allowance across a chosen operating horizon, initially 24 hours. Recompute the desired average as remaining discretionary attempts divided by remaining time, accounting for queued/reserved work. Keep short burst capability for interactive work and approved experiment blocks.
- **Experiment burst:** spend a fixed block, for example 100 attempts, at the allowed minute rate when independent work and concurrency permit. Debit it from the daily plan immediately. Returning to paced mode reduces later throughput rather than pretending the burst never happened.

With rolling-24-hour admission, replenishment follows the aging of old attempts; there is no midnight refill or arbitrary end-of-day sweep. With a verified daily reset, release unused discretionary headroom in the last two hours only when useful jobs fit before reset. Never rush calls across an assumed reset boundary.

Start with a 980-attempt working allocation. Allow up to 995 when retained owner/recovery reservations are no longer needed. The remaining five may serve legitimate owner or already-admitted continuation work, but automated discovery does not deliberately consume them to reach a round number. **The 980/995 planning targets do not trigger paid overflow:** release usable discretionary headroom to suitable free work before paying. A genuine reservation for other already-admitted work remains protected; it does not, by itself, justify paid discovery. If useful work or providers run out, report the reason for underutilization.

## 5. Count workflows, not just assignments

Repository inspection identifies these request consumers:

| Consumer | Accounting requirement |
|---|---|
| Research report and fallback | Count primary and separately admitted fallback independently. |
| Manual similarity check | Count every semantic batch; documented maximum is eight calls. Reuse local comparisons first. |
| Per-run chat | Count each model turn, including streamed failures. |
| Report evaluation | Count evaluator and clarification phases; documented allowance is six calls per report revision. |
| Research refinement | Count its own model request and preserve revision lineage. |
| Experiment setup/clarification/execution decision | Count each model phase; local numerical execution itself does not consume an OpenRouter request. |

Reserve a bounded request envelope for a work item and release unused future phases. Keep reservations separate from dispatched-attempt counts so the budget is not double charged. Reaching a workflow's current one-request or phase limit remains a stop even if the account has capacity.

Illustration: two models × ten identical research briefs × three planned replicates uses **60 inference attempts for the measured step**. If each result then receives one evaluation, that becomes 120; similarity checking, chat, retries, and other phases add further requests. The campaign planner must budget the complete pipeline or explicitly isolate the measured step in a bounded evaluation harness.

Avoid both extremes: allocating 1,000 assignments that secretly require thousands of calls, and permanently reserving every worst-case branch so almost nothing runs. Reserve the next bounded stage plus needed completion capacity, use fair queues, and update estimates from observed per-workflow costs.

## 6. Turn available capacity into useful experiments

Maintain a small ready backlog with a specific question, model/prompt version, allowed inputs, expected call count, acceptance rubric, stop rule, and output artifact. Local deduplication, arithmetic, data validation, caching, and numerical experiments should run without an LLM whenever they do not require one.

Initial research agenda:

1. **Capability baseline:** compare two currently approved free models on the same ten representative briefs with three replicates each. Score schema validity, supported claims, useful falsification rules, runner compatibility, latency, and accepted outputs per attempt. Rotate task order to reduce time-of-day/provider confounding.
2. **Prompt comparison:** change one factor at a time, using the same frozen task set and rubric. Include total downstream clarification/rework calls in the comparison. Keep a separate untouched task set for confirming an apparent improvement.
3. **Targeted discovery:** allocate most requests to hypotheses the current data and numerical runner can actually test; keep the Wildcard Sleeve for broader ideas with explicit feasibility questions.
4. **Adversarial passes:** challenge shortlisted ideas using missing-data checks, alternative explanations, and falsification criteria. Agreement between models is not independent economic evidence.
5. **Empirical follow-through:** run supported experiments locally against pinned real inputs, preserving failed and null findings. Ask models to interpret bounded measured results without fabricating unavailable observations.

Use 100-attempt campaign blocks rather than unbounded agent conversations. Stop a branch when its question is answered, its data/runner prerequisites are missing, or it repeatedly produces no actionable improvement. An initial model reliability rule can pause a model after three consecutive unusable responses for the same task contract and schedule diagnosis before more sampling.

Local reuse of an identical valid result saves an API call. Deliberately repeated sampling must be marked as a replicate and avoid caches that merely return the prior answer. Record provider/model identifiers and generation IDs when supplied; a stable model alias alone does not prove the underlying model or provider stayed constant.

Report throughput and research value separately: accounted attempts, accepted outputs, unique useful hypotheses, experiments actually completed, reproducible results, null findings, and total attempts per completed experiment. No request target renews a Testing Budget or converts exploratory results into confirmatory evidence.

## 7. Rejections, retries, and recovery

| Observation | Required behavior |
|---|---|
| Local admission delay | Persist `waiting for capacity` and next eligible time; do not send or consume an attempt yet. |
| Platform minute 429 | Count attempt, impose shared cooldown, honor credible reset/Retry-After, lower burst rate. Do not try another model to bypass it. |
| Platform daily 429 | Pause account free inference until a credible reset or conservative replenishment condition; no repeated probing. |
| Clearly provider-specific 429 | Cool down that route; unrelated healthy routes may continue inside global limits. A different model requires existing task routing/fallback permission. |
| Unknown-source 429 | Apply account-wide cooldown conservatively; do not assume it is only one provider. |
| 401/402/403 or deterministic request error | Stop the affected work for correction; no automatic funding, paid fallback, or identical invalid-request loop. |
| Timeout, crash after intent, partial/ambiguous response | Keep the attempt consumed and preserve indeterminate lineage. No automatic resend. |
| HTTP 200 stream containing an error | Record the actual failed/incomplete outcome; HTTP success alone does not complete the work. |

First rollout retains existing no-automatic-retry semantics. A later bounded recovery step may admit **one replacement attempt** after a definite transient rejection, only where the workflow explicitly permits another attempt. Existing one-request assignments need their established separate-child mechanism or an explicit versioned workflow change; a generic HTTP retry wrapper is insufficient.

Every replacement competes for the same daily and minute capacity. Persist its parent link and uniqueness. Honor `Retry-After` as seconds or HTTP date; validate reset-field units against provider evidence instead of assuming seconds. Missing or malformed hints use a conservative 60-second initial cooldown with increasing backoff and jitter on further incidents. Three repeated transient rejections in five minutes open a five-minute circuit for the proven scope; recovery allows one budgeted half-open attempt, not one per worker.

A platform rate-limit incident reduces the local burst ceiling, initially to 15/minute. Recover in one-request/minute steps after ten healthy active minutes at each level, capped at the configured 3.1-second cadence. Provider-specific incidents adjust the provider route rather than unnecessarily reducing every healthy route.

### Selected paid fallback, free first

Add a **Paid fallback model** selector separate from the current default model and free fallback. It selects one explicitly approved, concrete, inexpensive open-weight model. Validate published weight availability/license, task capabilities, context length, and current provider pricing when configuring it; a cheap price or vendor name alone does not establish open weights. Show input/output prices and a bounded cost preview. Prefer a model that passes the same representative task rubric rather than the lowest catalog price regardless of usefulness.

Fallback order and conditions:

1. Use the assigned suitable free route. If a provider-specific capacity failure occurs, use an already-approved suitable free alternative only through a budgeted, workflow-permitted replacement attempt. Never cycle through the entire catalog.
2. For minute-limit 429s, wait for replenishment. Do not buy an answer merely because a three-second slot is unavailable or a brief platform cooldown is active.
3. For genuine daily free exhaustion, allow new eligible work on the selected paid model if paid fallback is enabled and funds are reserved. Valid evidence is an authoritative daily-cap rejection or complete local accounting reaching the hard allowance. A local 980/995 target, unknown history, policy rejection, or exhausted per-work budget is not exhaustion evidence.
4. Offer a separate **Allow paid during prolonged free outages** setting, off by default to honor exhausting free usage first. If enabled, require at least ten minutes of observed unavailability across suitable approved free routes, no account/authentication/DDoS block, and a bounded work deadline that cannot tolerate waiting. Use only naturally required recovery attempts; do not spend free quota proving every model is down. Record `free_capacity_unavailable`, distinct from `daily_free_exhausted`.
5. At the next confirmed free replenishment or healthy free recovery, send new eligible work back to free models automatically. Do not cancel a paid request already dispatched. When paid work is active, an allowed half-open free request should do useful queued work, not a throwaway health prompt.

Use two UI modes: **Free only** and **Free first + paid fallback**. Within the second, default the trigger to **Daily allowance exhausted**; the prolonged-outage setting is additional and clearly disclosed. Minute throttling, unknown 429 source, moderation rejection, ambiguous acceptance, or missing price evidence never trigger paid fallback.

OpenRouter offers a server-side `models` fallback array, but it can advance on several error types and charges for the model ultimately used. Do not mix free and paid models in that array: choose the paid branch explicitly after checking reason and budget. Keep same-model provider routing inside approved capabilities and price ceilings. [OpenRouter model fallback behavior](https://openrouter.ai/docs/guides/routing/model-fallbacks), [provider routing controls](https://openrouter.ai/docs/guides/routing/provider-selection).

Proposed starting limits, configurable before activation:

| Paid setting | Proposal |
|---|---:|
| Maximum per request | $0.002 |
| Maximum per UTC day | $0.10 |
| Maximum per UTC calendar month | $2.00 |
| Maximum paid attempts/day | 100, also subject to monetary ceilings |
| Paid dispatch rate | Initially at most 5/minute; obey provider cooldowns |
| Output allowance | Existing phase bound, initially at most 2,048 tokens |

The stricter daily/monthly/per-request/account/work constraint always wins. No automatic top-up or budget increase. With these illustrative settings, the daily budget supports 50 requests at the maximum per-request reservation; cheaper requests can support more, up to the attempt ceiling. These are budget calculations, not claims about a selected model's price. Hosted open weights still incur inference charges; local self-hosting is a separate compute-capacity decision.

Before every paid dispatch, atomically reserve a conservative maximum dollar cost alongside its attempt and work identity. Bound total input, output, reasoning, and any other billable dimensions using current eligible-provider pricing and price caps. Disable unbounded/billable extras. If the adapter cannot establish an upper bound, do not send. Reconcile with reported usage afterward; missing cost or ambiguous outcome keeps the reservation encumbered, never releases it as zero. Unexpected charges stop the affected paid lane for reconciliation.

Maintain separate free-attempt and paid-dollar/attempt counters, with a common overall in-flight guard. Paid requests do not consume the free-request pool, but all spending paths, including existing paid manual assignments, must be included in an encompassing spending budget or explicitly reserved alongside it. A dedicated fallback subtotal is not an account spending cap.

Permit at most one replacement after a definite rejection under the recovery policy above; selecting a free alternative and then a paid model must not create an unbounded chain. Separately queued new work after daily exhaustion can use paid capacity directly. Record selected/returned model, parent failure if any, trigger, policy version, maximum reserved cost, and actual reported cost. A model change remains visible in research provenance and must respect model-pinned experiments: mark a substitution as a distinct condition or leave the experiment queued rather than corrupting a comparison.

## 8. Integration constraints discovered locally

- Non-streaming generation is centralized in `backend/src/incubator.rs` through `OpenRouter::send_with_parser`; streaming chat posts separately in `backend/src/incubator_chat.rs`. Both must use admission. Making raw client/auth fields private helps prevent future bypasses.
- `backend/src/incubator_requests.rs`, `backend/src/incubator_evaluation.rs`, `backend/src/incubator_refinement.rs`, and `backend/src/incubator_experiment.rs` provide purpose and phase context to the shared transport. Queue waits must preserve their existing intent/recovery contracts.
- `backend/src/openrouter_request.rs` adapts capabilities; it is not currently an account rate limiter. Keep request adaptation distinct from durable admission.
- Current code permits paid manual assignments through `prepare_model_with_spend` and removes zero-price caps from their payloads. Parts of `docs/incubator-agent-poc.md` still describe an entirely free-only POC. Update that documentation during integration. The proposed campaign's free branch must explicitly require an approved concrete `:free` model, verified zero pricing, and zero-price caps even when reusing a manual-assignment creation path. The paid branch needs an explicit fallback decision, bounded provider price caps, and an atomic spending reservation; the existing manual boolean is insufficient. An origin label must not accidentally grant spending permission.
- Current payloads allow provider fallback for the same model. Record the returned provider when available; count client inference attempts and do not invent visibility into internal provider retries. Client-side model fallback still needs its own ledger entry and task permission.
- Keep existing per-run locks, phase limits, and uncertain-outcome holds. Introduce a modest global in-flight ceiling, initially four, without widening narrower existing limits. If measurements show serialization prevents the desired burst rate, a separate change must establish safe per-work-item claims and bounded concurrency before raising it. The quota feature alone does not make 20/minute achievable.

## 9. What the user should see

Extend Agents with a compact capacity panel alongside the existing credit display:

- `Attempts accounted: 742 / 1,000`, explicitly local accounting.
- `Available for new work: 198`, derived after consumed attempts, outstanding reservations, and retained headroom; explain the breakdown.
- Current minute utilization, configured start interval, in-flight count, and limiting factor.
- Queue size, next eligible request, daily-window mode, and reset/replenishment estimate with its evidence status.
- Accepted-output rate and attempts per completed experiment; provider rejects and indeterminate outcomes separately.

Incubator should show `Waiting for request capacity`, `Provider cooling down`, or `Daily allocation used` instead of a generic failure/spinner. Queue state survives browser closure. Stop/pause cancels only work that has not dispatched; it does not claim to cancel already-running provider compute.

Provide paced/burst selection, a bounded burst size, and a pause control through existing owner workflow patterns. Show forecasted remaining capacity before a burst. Keep routine counters quiet; surface actionable credential, persistent provider, unexpected-charge, and accounting-integrity failures. No separate scheduled notifications are created by this plan.

Show the separate paid fallback selector, activation mode, optional outage trigger, and request/day/month ceilings together. While in use, display `Using paid fallback: daily free allowance exhausted` or the distinct enabled outage reason, selected model, reserved/actual spending, and remaining budget. A budget stop leaves the work queued. Reverting to free should be visible without requiring an owner to switch models back manually.

## 10. Delivery sequence and proof

| Phase | Deliverable | Exit evidence |
|---|---|---|
| 1. Establish accounting | Inventory/seeding of all dispatch consumers, durable attempt identity and totals, known account scope | Existing intents reconcile; unknown history is explicit; key rotation and restart do not reset allowance |
| 2. Enforce admission | Shared daily/minute checks and persistent waiting state on both streaming and non-streaming paths | Simultaneous workers cannot exceed limits; delayed workers cannot release a catch-up burst; no raw transport bypass |
| 3. Expose capacity | Agents counters and Incubator wait reasons with reservations and replenishment | UI agrees with ledger, failures do not show stale availability, browser reconnect does not resubmit |
| 4. Add bounded scheduling | Paced mode, 100-attempt blocks, fair priority, per-work budgets and free-branch eligibility | Full workflow cost fits reserved allowance; no new autonomous jobs beyond campaign limits; no accidental paid route selected |
| 5. Calibrate and recover | Small measured ramp, eligible rejection recovery, cooldowns, selected paid fallback and spending reservations | Free-first decisions and all dollar caps hold; recovery preserves phase rules, does not replay ambiguity, and never causes a fallback/retry storm |
| 6. Tune useful throughput | Task/model benchmarks, adaptive allocation, optional separately proven concurrency increase | Higher accepted experiments per attempt; 980–995/day achievable when supply and provider capacity permit |

Before live calibration, use a fake clock and provider with an isolated database to exercise: 21 simultaneous requests; the 1,001st daily attempt; minute/day edges; two service instances; crashes before/after intent; database outage; clock jumps; queued cancellation; duplicate submission; fallback and similarity batches; SSE errors; malformed limit headers; policy revocation while waiting; and a free campaign accidentally routed through manual paid dispatch. Assert actual outbound attempt counts rather than only reported counters. No live quota is needed for these checks.

Paid fallback acceptance must additionally prove: a minute 429 does not spend; one unhealthy free route does not establish total free exhaustion; reaching 995 does not trigger paid overflow; daily exhaustion can select the configured eligible paid model; missing budget/model/price evidence blocks spending; concurrent requests cannot oversubscribe the final dollar reservation; partial or unknown paid outcomes retain cost reservations; day/month changes retain commitments for unresolved attempts conservatively; returned charges are reconciled; unapproved model changes cannot alter a benchmark; and new work returns to free after replenishment. Test the optional outage trigger separately from the default strict free-first behavior.

Run the applicable existing Incubator acceptance suites plus Rust/frontend checks when implementing. Add a dedicated isolated quota acceptance scenario and preserve its evidence through the repository's normal work-unit workflow. Refresh repository/issue state before assigning work-unit numbers; this operating plan does not claim those implementation units are already approved or completed.

Live rollout after implementation:

1. Use a **100-attempt maximum calibration block**, included in that day's allowance: 20 attempts at 5/minute, 30 at 10/minute, then up to 50 at the initial 18.75/minute setting. Progress only if real latency/concurrency permits and no platform-limit/accounting defect appears.
2. Run two operating windows capped at 950 attempts each. Check failed-attempt accounting, request costs per workflow, replenishment behavior, and owner responsiveness.
3. Raise the working allocation to 980, release discretionary capacity toward 995, and tune to 3.1-second starts after healthy evidence. Retain the hard 1,000 ceiling and all cooldowns.
4. If provider capacity remains poor, rotate only among approved suitable free routes, schedule batches at different times, or do local research until recovery. Use the selected paid model only under the enabled exhaustion/outage policy and selected spending ceilings. No new accounts, automatic purchases, or uncapped paid fallback.

Success means nearly all *usable* allowance advances a bounded research agenda, every possible request is accounted for, no client-controlled quota overshoot occurs in verification, and no unexpected spending or ambiguous-request replay is introduced. Provider acceptance and a full daily workload remain measured conditions, not guarantees.
