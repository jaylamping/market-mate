# WU-27 thermo-nuclear review

**Round 2: 0 open bugs.**

Branch: `jl/wu-27-core-indicator-computation` (HEAD = `main` 871282b; work is uncommitted)
Base: `main` (871282b)
Diff this round: untracked working tree vs round 1

Round 1 found 0 bugs and two suggestions (design-history comment; UPDATE/DELETE/TRUNCATE probes swallowing `probe corrupted`). Both are fixed in SQL/probe, not just claimed. Notes from round 1 are not re-litigated.

Verified by reading `0028_core_indicator_computation.sql` definition resolution, the probe’s `retired_latest_does_not_fallback` / append-only / rebind paths, the acceptance-script gate list, and evidence JSON. Bring-up log ends `WU-27 COMPLETE`. Migration 28 checksum changed with the comment drop (`cd87444e…` → `c452eb37…`).

## Highs checked

| # | Item | Result |
|---|---|---|
| 1 | Point-in-time leaks | **OK.** Unchanged. |
| 2 | Look-ahead | **OK.** Unchanged. |
| 3 | Experimental indicators as Core | **OK.** Unchanged. |
| 4 | Missing / incomplete / disputed becoming 0 or last-known-good | **OK.** Unchanged. |
| 5 | Retired core v2 falling back to v1 at later as_of | **OK.** Issue 1’s comment is gone; the latest-then-declared path is now probed (see Issue 1 / High 5 below). |
| 6 | Unique-constraint / audit event_id collisions | **OK.** Unchanged. |
| 7 | Direct INSERT bypassing workflow | **OK.** Unchanged. Append-only UPDATE/DELETE/TRUNCATE probes now match WU-26 (Issue 2 fixed). |
| 8 | Advisory lock on the unique key | **OK.** Unchanged. |
| 9 | Digest timezone dependence | **OK.** Unchanged. |
| 10 | PL/pgSQL RETURNS TABLE / variable vs column ambiguity | **OK.** Unchanged. |
| 11 | CREATE OR REPLACE dropping SECURITY DEFINER / search_path / privilege revoke | **OK.** Unchanged. |
| 12 | Comments that narrate WHAT | **OK.** Issue 1 fixed. File header remains; no resolution-history comment. |
| 13 | Public EXECUTE left on write functions | **OK.** Unchanged. |
| 14 | Idempotent recompute hiding look-ahead | **OK.** Unchanged. |
| 15 | Calendar used for freshness lag including post-as_of sessions | **OK.** Unchanged. |
| 16 | Using undeclared inputs | **OK.** Unchanged. |
| 17 | Evaluation rebind to a different definition version succeeding | **OK.** Rebind now raises `probe corrupted` if accepted and only treats SQLSTATE `23505` as success. |
| 18 | as_of in the future accepted | **OK.** Unchanged. |

## Issues

### Issue 1 -- Severity: suggestion
- **File**: db/migrations/0028_core_indicator_computation.sql:200
- **Description**: (Round 1) `-- Latest PIT version first, then keep it only if still declared. A later retired v2 must not resurrect v1 (same rule as coverage_core_indicator_ids_as_of).` restated the following `SELECT` / lifecycle filter.
- **Suggestion**: Drop it. Fail-closed retirement is already in the file header.
- **Status**: fixed

  Round 2 verification: that comment is gone. `core_indicator_definition_for_compute` still `ORDER BY v.version DESC LIMIT 1` under `effective_from` / `receipt_time` <= as_of, then requires `indicator_kind = 'core'` and as-of lifecycle `declared` (`0028:200-232`). Only remaining `--` lines are the file header.

  Probe `retired_latest_does_not_fallback`: `record_indicator_definition_lifecycle(v_core_v2.definition_version_id, 'retired', ...)` then `compute_core_indicator_observation(..., clock_timestamp(), ...)`. Success would raise `probe corrupted: retired v2 fell back to a predecessor`, which does not match `%retired core indicator % cannot be computed%` and re-raises. The accepted path requires that message, then `preview_core_indicator_observation(..., v_t1, 20)` still has `definition_version_id = v_core` (v1). Evidence `gates.retired_latest_does_not_fallback` is true.

### Issue 2 -- Severity: suggestion
- **File**: db/fixtures/wu27_core_indicator_computation_probe.sql:457
- **Description**: (Round 1) UPDATE / DELETE / TRUNCATE raised `probe corrupted` and `WHEN OTHERS THEN v_* := true`, so a missing append-only trigger would still pass.
- **Suggestion**: Match WU-26: re-raise unless `SQLERRM LIKE '%append-only%'`.
- **Status**: fixed

  Round 2 verification: UPDATE, DELETE, and `TRUNCATE indicator_observation, indicator_evaluation_binding` each `IF SQLERRM NOT LIKE '%append-only%' THEN RAISE`. Triggers still raise `indicator_observation is append-only; % is forbidden` / `indicator_evaluation_binding is append-only; % is forbidden`. Truncating both tables in one statement means a missing observation trigger cannot be masked by the binding FK.

## Notes (not issues)

- Rebind hardening is extra coverage, not a round-1 issue: accepted rebind now raises `probe corrupted: evaluation rebind to a new definition version was accepted`; only SQLSTATE `23505` sets `v_rebind_blocked`.
- Round-1 notes on unused `expired` / `not_applicable`, single-horizon binding unique, canonical horizon `1` vs t-20 formula, and `indicator_observation_at` lookup vs compute `receipt_time` are unchanged and not re-litigated.
- No new env vars, ports, or mandatory setup. Head is still migration 28.
