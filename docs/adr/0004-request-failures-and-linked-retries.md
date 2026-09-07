# ADR-0004: Link failures and retries to originating requests

- Status: accepted
- Date: 2026-09-07
- Decision source: Retrospective: user-directed campaign recovery and [PR #151](https://github.com/jaylamping/market-mate/pull/151).
- Implementation: implemented in the linked scope; limitations are stated below.

## Context

Generic failed cards hid distinct policy, capacity, and response-validation problems. Calls that failed before dispatch were absent from a receipt-only projection.

## Decision

Record stage/reason and available bounded diagnostics against the originating request. Include pre-dispatch creator failures. Give a retry a new identity and a parent link while preserving the original result; guard against duplicate retry submission and uncertain provider outcomes.

## Alternatives and consequences

Resetting a failed row loses history. Logging only to console disconnects failures from the product. Response evidence must remain bounded and must not expose credentials. During database unavailability a durable write may be impossible; request-linked service logs and restart reconciliation are required fallbacks. Old unrecorded response bodies cannot be reconstructed.

## Verification

[creator](../../backend/src/incubator_ticket_creator.rs), [output diagnostics](../../backend/src/incubator_output.rs), [recovery SQL](../../db/migrations/0079_campaign_recovery.sql), [recovery probe](../../db/fixtures/campaign_recovery_probe.sql). Run `bash scripts/research_campaign_test.sh`. This records the implemented campaign behavior and the desired pattern for other request paths, not a claim that every subsystem already has identical coverage.

## Reconsider when

Adding a new request workflow or changing retention requirements; preserve lineage and verify the actual failure path.
