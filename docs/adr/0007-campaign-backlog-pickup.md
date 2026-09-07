# ADR-0007: Keep existing campaign backlog moving

- Status: accepted
- Date: 2026-09-07
- Decision source: User-directed fix after live campaign cards failed similarity checking and stopped being admitted to free research workers.
- Implementation: implemented in [0080](../../db/migrations/0080_campaign_backlog_pickup.sql), [similarity filtering](../../backend/src/incubator_requests.rs), and [campaign finish/claim](../../db/migrations/0080_campaign_backlog_pickup.sql).

## Context

An incomplete similarity check marked the candidate `blocked` and disabled the campaign. Later cards stayed in the UI queue with no research worker. When a check did complete, topical overlap with earlier generic momentum briefs was treated as a duplicate even when the model's own reason called the case a sensitivity test.

## Decision

Pause stops Ticket Creator only. Existing backlog cards still receive a free-model similarity check and can be admitted. A comparison already claimed is cancelled only when campaign settings revision changes, not merely because generation is paused. Incomplete or interrupted checks keep the original result, queue a linked retry, and leave campaign `enabled` unchanged. A duplicate is the same exact momentum_v1 lookback, quantile count, one-way cost, and borrow cost. Topic overlap and different parameter cases stay in the live queue. Uncertain provider outcomes still block another dispatch.

## Alternatives and consequences

Continuing to disable the campaign on every incomplete check preserves operator review and starves the visible queue. Treating every model-reported match as a duplicate is stricter than the written exact-case rule and hides distinct sensitivity tickets. Admitting after an incomplete check without a retry would raise missed-duplicate risk.

## Verification

[pickup probe](../../db/fixtures/campaign_backlog_pickup_probe.sql), [campaign probe](../../db/fixtures/research_campaign_probe.sql), [recovery probe](../../db/fixtures/campaign_recovery_probe.sql). Run `bash scripts/research_campaign_test.sh`. Live queue state is a runtime observation, not fixture proof.

## Reconsider when

A similarity model has a verified exact-case contract, or campaign pause is redefined to include backlog admission. Preserve linked retries and indeterminate receipts.
