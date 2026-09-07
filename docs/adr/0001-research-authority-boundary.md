# ADR-0001: Separate research output from trading authority

- Status: accepted
- Date: 2026-09-07
- Decision source: Retrospective: existing Local Research implementation, not a new Principal policy decision.
- Implementation: implemented in the linked scope; limitations are stated below.

## Context

The domain model spans later execution stages, but the running research application can produce plausible plans without establishing economic evidence or order authority.

## Decision

Treat model output as untrusted research input. Keep research/configuration writes separate from Paper/Live execution permissions. Keep dataset contracts, diagnostic results, and authority decisions explicit.

## Alternatives and consequences

A single agent with research and execution authority would make generated claims actionable without independent admission. Describing every page as read-only would also be inaccurate: local research controls do mutate state.

## Verification

[worker entrypoint](../../backend/src/bin/incubator-requests.rs), [read-only Paper connector](../../backend/src/paper.rs), and [campaign contract migration](../../db/migrations/0074_research_campaign.sql). Checks: `bash scripts/research_campaign_test.sh` and `bash scripts/wu39_incubator_substrate_test.sh`; fixture success does not qualify a strategy.

## Reconsider when

A separately authorized later-stage execution capability is implemented and verified; update the stage map and controls together.
