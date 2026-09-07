# ADR-0010: Retry unusable Research Scout replies; campaign paid creator is Ticket Creator only

- Status: accepted
- Date: 2026-09-07
- Decision source: User-directed after three campaign Research Scout tickets failed (`incomplete_response`, `invalid_report`) and those tickets were archived rather than retried. Later reversed: a paid Ticket Creator does not authorize automated Research Scout. Campaign is a manual backlog generator for now; automated workers stay free unless the owner turns on automated paid spending.
- Implementation: implemented in [0083](../../db/migrations/0083_research_retry_campaign_paid.sql), [0086](../../db/migrations/0086_campaign_paid_research_authorize.sql), [Research Scout](../../backend/src/incubator.rs), [capacity admission](../../backend/src/openrouter_capacity.rs), and [campaign worker](../../backend/src/incubator_campaign.rs). Campaign Check later moved to a local exact-case comparison in [ADR-0011](0011-campaign-exact-case-check.md).

## Context

Campaign Research Scout used the free creator (`inclusionai/ling-3.0-flash-fin:free`). Two replies hit the 2048-token cap after starting a JSON fence. One finished with `evidence_gaps` as a string. Those failures were terminal. The owner archived `#20`, `#22`, and `#24` and asked that new tickets not fail the same way. Ticket Creator was already allowed to use the paid creator. Binding Research Scout to that same paid creator ignored Agent configuration and automated-spend-off. The owner uses campaign to stock the backlog by hand; later automation must not spend.

## Decision

Research Scout disables reasoning, asks for the `research_scout` JSON schema, and repairs an enclosing fence, a first JSON object, and a string coerced to a one-element list. One automatic `research_retry` is allowed after `incomplete_response` or `invalid_report`. Archived runs are not picked up. A paid campaign creator authorizes Ticket Creator only. Campaign Check is a local exact-case comparison and does not spend that creator; see [ADR-0011](0011-campaign-exact-case-check.md). Research Scout uses the configured Research runner. Automated workers stay on `:free` routes while global `paid_enabled` is off. Undispatched campaign research that was bound to the paid creator is rewritten onto that free runner. Evaluation, refinement, and experiment stay on free routes.

## Alternatives and consequences

Retrying the archived three would spend again on known-bad first replies. Raising `max_tokens` without a schema still wastes a cutoff on fences. Enabling global paid automation would spend outside the owner-selected Ticket Creator call. Keeping Research Scout on the paid creator spends on every automated ticket. Keeping leftover paid-bound admissions would stall or spend after deploy. Those undispatched rows are rewritten in place because `incubator_agent_run` is otherwise append-only.

## Verification

[research retry probe](../../db/fixtures/research_scout_retry_probe.sql), existing campaign probes, Research Scout unit tests, frontend run-state parse tests, `bash scripts/research_campaign_test.sh`, `bash scripts/verify.sh`. The archived live tickets stay archived.

## Reconsider when

The owner turns on automated paid spending, or authorizes paid evaluation or experiment workers.
