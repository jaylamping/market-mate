# ADR-0009: Acquisition worker timeout and attachment-failure retry

- Status: accepted
- Date: 2026-09-07
- Decision source: User-directed recovery of campaign tickets left `awaiting_data` after `commit_rejected`.
- Implementation: implemented in [0082](../../db/migrations/0082_acquisition_commit_retry.sql), [acquisition worker](../../backend/src/market_data_connection.rs), and [acquisition controls](../../frontend/lib/market-data.ts).

## Context

The market-data HTTP helpers apply a 5-second `statement_timeout`. The Compose acquisition worker reused that connection. Reusing a same-day 20-name, 60-session panel takes about 12 seconds in `read_market_data_acquisition_cache`. The cancel was recorded as `commit_rejected`, which is not auto-retried and consumed the three-attempt budget. SQL as `mm` succeeded because its timeout is 0. Tickets 21 and 23 reached attempts=3 and the UI hid Retry.

## Decision

The acquisition worker raises its session `statement_timeout` to 180 seconds after connect, matching the download bound plus cache assembly. Statement timeouts map to `download_timeout` so remaining budget can auto-retry. `commit_rejected` stays operator-retryable after the attempt cap: Retry resets attempts to 2 and requeues the same frozen request. Price, coverage, and invalid-request failures still need a new experiment after three attempts.

## Alternatives and consequences

Skipping the local cache would avoid the slow read but discard a completed same-day panel. Raising the HTTP 5-second timeout would stall request handlers. Raw updates of acquisition rows would rewrite evidence. Starting new experiments would work and waste Setup that already produced a valid `data_request`.

## Verification

Frontend `canRetryAcquisition` tests. Live cache read of the #17 panel (~12s, ~187KB) under a 5-second timeout reproduces the failure. After deploy, #21 and #23 should attach from cache without a new Alpaca download.

## Reconsider when

Cache assembly stays under the request-handler timeout, or attachment failures are stored as distinct SQL reasons instead of a catch-all `commit_rejected`.
