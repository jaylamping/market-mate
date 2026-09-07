# ADR-0011: Deterministic campaign exact-case checks; drain the Created queue

- Status: accepted
- Date: 2026-09-07
- Decision source: User-directed after Ticket Creator stocked the backlog and Check stayed on one card (`#26`) while later cards remained Created. The owner asked to raise likeness/duplicate throughput up to provider rate limits, including caching or pgvector.
- Implementation: implemented in [0085](../../db/migrations/0085_campaign_exact_case_check.sql), [campaign worker](../../backend/src/incubator_campaign.rs), and [campaign check](../../backend/src/incubator_requests.rs). This replaces the claim-spacing decision in [ADR-0008](0008-campaign-experiment-throughput.md). Experiment-reply retry in ADR-0008 stays.

## Context

Campaign admission already treats a duplicate as the same momentum_v1 lookback, quantile count, one-way cost, and borrow cost. Ticket Creator also rejects those occupied cases. Check still sent the assignment corpus to a model in batches, then discarded every non-exact match. That call is the stall: one card waits on OpenRouter while the others stay Created. A 10-second claim timer and a single `checking` row kept the queue serial even after a check returned. pgvector and embedding caches find topical neighbors. Those neighbors are not duplicates under the current contract.

## Decision

Campaign Check compares the pinned assignment corpus locally for that exact four-tuple. It does not call a model, reserve capacity, or wait on `next_at`. The campaign worker claims and finishes every eligible Created card in one tick until the daily limit, unfinished-ticket limit, or empty backlog stops it. A claimed check still resumes after a crash; a recorded result stays immutable. Manual assignment similarity stays on the existing model path. Paid campaign creator authority remains for Ticket Creator only. Research Scout and later campaign stages stay on free routes while automated paid spending is off.

## Alternatives and consequences

Keeping the model comparison and only adding parallel HTTP still spends paid creator time on a question SQL already answers, and still 429s on a shared pool. Embedding the corpus would optimize topical likeness, which Check must not treat as a duplicate. Caching model replies does not help new specs. Removing the claim timer without a local check would only start more provider calls.

## Verification

[campaign exact-case probe](../../db/fixtures/campaign_exact_case_check_probe.sql), existing campaign probes, Rust exact-case unit tests, `bash scripts/research_campaign_test.sh`, `bash scripts/verify.sh`. Live cards already in `checking` keep a recorded result if one exists; an unfinished live check can complete locally after deploy.

## Reconsider when

The owner asks Check to block on topical likeness again, or a new diagnostic runner needs a comparison that the four-tuple cannot express.
