# ADR-0012: Deterministic diversity controls on Ticket Creator intake

- Status: accepted
- Date: 2026-09-07
- Decision source: User-directed after the campaign backlog filled with tickets whose titles and premises restated the same short-horizon momentum question with a different cost number. The owner asked for a way to vary what the creator proposes.
- Implementation: implemented in [0087](../../db/migrations/0087_campaign_near_duplicate_intake.sql) and [ticket creator](../../backend/src/incubator_ticket_creator.rs). Builds on the lens rotation merged in PR #159.

## Context

The only implemented diagnostic is momentum_v1 with four integer fields. ADR-0011 defines a duplicate as the exact four-tuple, so a proposal at 12 bps one-way cost is admitted beside an occupied case at 10 bps even though the two experiments answer the same question. The creator prompt asked for a new exact case and got exactly that: a new number and the same premise. Prompt text alone cannot enforce novelty, and a rejection recorded as `failed` would trip the three-consecutive-failure auto-disable in `finish_incubator_ticket_generation`. LLM alpha-mining literature reports the same collapse and answers it with a novelty check against the existing library (AlphaAgent, KDD 2025) rather than with more instructions.

## Decision

Three deterministic controls, all at creator intake:

1. **Lens rotation.** Each generation job receives one of eight research lenses chosen by `job_id mod 8`. The system prompt requires the title to name the lens and the exact case and the premise to open by stating what changed relative to the used cases.
2. **Near-duplicate bucket.** `incubator_momentum_case_bucket(spec)` maps a case to `(lookback_sessions, quantile_count, floor(one_way_cost_bps / 10), floor(borrow_bps_per_session / 10))`. A completed proposal whose bucket is already occupied by a backlog candidate or an assignment is recorded as `completed` with `deduplicated`, `near_duplicate`, and `nearest_case`, inserts no candidate, and does not count toward auto-disable. The creator receives the occupied buckets and the bin rule in its user message.
3. **Literature anchors.** Each job also receives two bibliographic anchors (authors, year, venue, one sentence of claim in our own words, one caution) selected by lens and rotated by `job_id / 8`. They are labelled research premises and never evidence. No text is retrieved or copied from external datasets; the anchors are constants in the creator module.

Campaign Check and manual assignment admission keep the exact four-tuple contract from ADR-0011. This decision narrows creator intake only.

## Alternatives and consequences

Rejecting near-duplicates in the Rust parser records a failure and can pause the campaign after three such replies. A weighted distance metric over four integers adds a threshold to tune without adding a decision the bucket cannot express. Applying the bucket at Check would reopen ADR-0011 and change what manual assignments may run. Vendoring Open Source Asset Pricing signal descriptions would import GPL-2 text; the anchors cite the original papers instead. The bucket still wastes one paid creator call per near-duplicate reply, the same cost the exact-case dedup already accepts. Eight lenses over one diagnostic saturate after a few dozen tickets; the ceiling is the single runner, not the prompt.

## Verification

[near-duplicate probe](../../db/fixtures/campaign_near_duplicate_probe.sql) proves bucket construction, the used-bucket list, near-duplicate skip with marker and nearest case, distinct-bin insert, exact-repeat marker, and that the campaign stays enabled. Rust unit tests prove lens rotation, anchor coverage per lens, and the bucket sentence in the request. `bash scripts/research_campaign_test.sh`, `bash scripts/verify.sh`. Live effect on ticket variety requires the campaign to run against a provider and is not fixture-provable.

## Reconsider when

A second diagnostic runner exists and needs its own bucket definition, the owner wants near-duplicate checks at Check or manual admission, completed experiments are numerous enough to add correlation-based diversity, or the owner authorizes retrieval of external literature at generation time.
