# ADR-0010: Retry unusable Research Scout replies; campaign paid creator for research

- Status: accepted
- Date: 2026-09-07
- Decision source: User-directed after three campaign Research Scout tickets failed (`incomplete_response`, `invalid_report`) and those tickets were archived rather than retried.
- Implementation: implemented in [0083](../../db/migrations/0083_research_retry_campaign_paid.sql), [Research Scout](../../backend/src/incubator.rs), [capacity admission](../../backend/src/openrouter_capacity.rs), [campaign worker](../../backend/src/incubator_campaign.rs), and [similarity comparison](../../backend/src/incubator_requests.rs).

## Context

Campaign Research Scout used the free creator (`inclusionai/ling-3.0-flash-fin:free`). Two replies hit the 2048-token cap after starting a JSON fence. One finished with `evidence_gaps` as a string. Those failures were terminal. The owner archived `#20`, `#22`, and `#24` and asked that new tickets not fail the same way. Ticket Creator was already allowed to use the paid creator; later workers were still forced onto free routes.

## Decision

Research Scout disables reasoning, asks for the `research_scout` JSON schema, and repairs an enclosing fence, a first JSON object, and a string coerced to a one-element list. One automatic `research_retry` is allowed after `incomplete_response` or `invalid_report`. Archived runs are not picked up. When the campaign creator is paid, claim, similarity, and Research Scout may use that same creator under `campaign_selection` and the existing paid reservation caps. Evaluation, refinement, and experiment stay on free routes. Global `paid_enabled` stays off unless the owner changes it.

## Alternatives and consequences

Retrying the archived three would spend again on known-bad first replies. Raising `max_tokens` without a schema still wastes a cutoff on fences. Enabling global paid automation would spend outside the campaign creator contract. Keeping research free-only repeats the same cutoff and type errors on the free pool.

## Verification

[research retry probe](../../db/fixtures/research_scout_retry_probe.sql), existing campaign probes, Research Scout unit tests, frontend run-state parse tests, `bash scripts/research_campaign_test.sh`, `bash scripts/verify.sh`. The archived live tickets stay archived.

## Reconsider when

The owner authorizes paid evaluation or experiment workers, or a more reliable free Research Scout model is the selected creator.
