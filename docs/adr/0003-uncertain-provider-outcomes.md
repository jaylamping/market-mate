# ADR-0003: Preserve uncertain provider acceptance

- Status: accepted
- Date: 2026-09-07
- Decision source: Retrospective: existing capacity/transport policy and request recovery implementation.
- Implementation: implemented in the linked scope; limitations are stated below.

## Context

A timeout, interrupted process, or failed receipt write can occur after a provider accepted a request and incurred cost.

## Decision

Retain indeterminate outcomes and unknown reservations. Reconcile uncertainty before another dispatch. Distinguish definite rejection and policy-gated recovery from unknown acceptance. Releasing a stale concurrency slot does not release the accounting uncertainty.

## Alternatives and consequences

Blind retries improve apparent liveness while risking duplicate work and hidden costs. Conservative uncertainty can require operator investigation; that cost is explicit.

## Verification

[transport](../../backend/src/incubator.rs), [capacity](../../backend/src/openrouter_capacity.rs), [capacity recovery SQL](../../db/migrations/0070_openrouter_capacity_recovery.sql). Run `bash scripts/openrouter_capacity_test.sh` and `bash scripts/research_campaign_test.sh`.

## Reconsider when

A provider offers a verified idempotency/reconciliation contract. Add adapter-specific proof before relaxing any retry condition.
