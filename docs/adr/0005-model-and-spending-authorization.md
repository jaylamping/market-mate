# ADR-0005: Separate availability, selection, and spending authorization

- Status: accepted
- Date: 2026-09-07
- Decision source: Retrospective: persisted routing/capacity rules and campaign-specific selection.
- Implementation: implemented in the linked scope; limitations are stated below.

## Context

A model may be advertised by a provider or available through an IDE without being approved for Market Mate dispatch. Manual, automated, and campaign-selected calls have different spending contracts.

## Decision

Consume persisted model approvals and the applicable dispatch policy. Keep campaign paid-creator selection scoped to that creator for Ticket Creator, similarity, and Research Scout. Later campaign evaluation and experiment stages stay free-only. Preserve capability, token, price, reservation, and unknown-cost gates when adapting or recovering a request.

## Alternatives and consequences

Choosing a similar available model or assuming that a free label grants permission erases the Principal boundary. Keeping separate approval and routing concepts adds checks but makes cost and authority reviewable. Do not generalize automated caps to explicit manual calls; read the exact policy path.

## Verification

[routing](../../backend/src/model_routing.rs), [capacity](../../backend/src/openrouter_capacity.rs), [campaign spending SQL](../../db/migrations/0076_campaign_selected_spending.sql), [capability adapter](../../backend/src/openrouter_request.rs). Run `bash scripts/openrouter_capacity_test.sh` and `bash scripts/research_campaign_test.sh`.

## Reconsider when

The Principal explicitly changes a spending/model policy or a provider contract changes. An agent/IDE transition alone grants nothing.
