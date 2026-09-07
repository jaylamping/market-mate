# Automated model selection and request capacity

The Settings page separates model preference from spending authorization.

- **Prefer free models** starts enabled. Automated research, evaluation, setup, experiments, and refinement retain their free route until daily free capacity is exhausted, or another explicitly enabled fallback condition applies.
- Turn the preference off to use the configured paid role model as the primary automated route. Paid spending must also be enabled. Role choices resolve to Research, Setup, Experiment, then the shared default; unassigned roles use the shared model. Refinement uses the Research choice.
- Explicit manual paid selections keep their selected model and bypass automated allowlists and dollar caps. They remain subject to model approval, provider availability, and the dispatch pause. Manual paid usage is accounted separately.
- Paid automation starts disabled, with no selected models. Default caps are $0.002 per attempt, $0.10 per UTC day, $2 per UTC month, and 100 attempts per rolling 24 hours. Unknown paid costs retain their reservations. Preference changes never raise caps or purchase credits.

## Free capacity

All inference transports require one database admission permit before sending. The account gate commits at most 20 free starts in a 61-second guard window and 1,000 in a rolling 24-hour window. This intentionally uses conservative local accounting instead of inferring a provider reset time. Starts are spaced by at least 3.1 seconds; the default burst interval is 3.2 seconds. Paced mode spreads the default 980-attempt target across the day. The target is pacing, not a separate quota. A bounded 100-attempt burst advances already queued work; it does not create research tasks or spend idle allowance on empty requests.

Counts cover research, chat, similarity checks, evaluation, refinement, and experiment stages. The migration inventories persisted recent dispatches before enabling new accounting. Deployment must replace all old dispatchers together; another application using the account would require shared accounting or a reduced allocation. Market Mate is currently the only account consumer.

## Rate-limit recovery

A known free minute limit cools down free traffic; an unknown platform limit cools down all traffic. Provider limits cool down the selected model. Retry hints and exponential backoff are retained. A free daily rejection uses a credible retry hint or conservatively waits 24 hours.

**Finish active work on paid after a definite 429** starts disabled. When enabled, one paid continuation is allowed by default, configurable to two. Each continuation is bound to a recent rejected free request and shares its original prompt and output allowance. A second continuation requires a definite 429 rejection of the first. Each attempt receives a separate immutable receipt and spending reservation. Available configured models can replace a cooling-down paid model. Recovery may wait briefly for the separate paid pacing gate; otherwise the current attempt ends without a hidden queued resend. Timeouts, partial responses, and unknown acceptance never qualify for paid replay.

Optional outage fallback requires ten minutes of observed unavailability across the configured free model set. New work returns to free when the fallback condition clears and Prefer free models remains enabled. With the preference off, paid primary routing remains in effect until changed.

## Operations and evidence

The capacity panel exposes local free counts, queued work, cooldowns, automated spending, and unresolved reservations. Request details include actual model, paid trigger, and capacity attempts. Prompt content is not copied into the capacity ledger; it stores hashes and routing metadata. A crashed transport loses its concurrency slot after 150 seconds while retaining its dispatch count and unknown monetary reservation. An unresolved committed request is never automatically resent.

Model policy and capacity policy must both permit an automated paid route. Current catalog pricing must support a conservative text-input/output reservation; unsupported billable dimensions stop paid admission. Current output limits remain bounded at 2,048 tokens. This is research execution only and grants no trading authority.

Run `bash scripts/openrouter_capacity_test.sh` for isolated migration, restricted-role mutation, policy, recovery, and concurrent admission probes. JSON results are stored in `evidence/openrouter-capacity/acceptance.json`. No inference requests are issued by this acceptance test.

Source: [OpenRouter limits and 429 handling](https://openrouter.ai/docs/api_reference/limits), checked 2026-09-07. Free account limits depend on cumulative purchased credits; multiple API keys do not create independent account allowances.
