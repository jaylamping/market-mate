# WU-24 thermo-nuclear review

**Round 2: 0 open bugs.**

Branch: `jl/wu-24-fitness-admission` (HEAD 96bfbf1; round 1 was 982ea64)
Base: `main` (7c2b41a)
Diff this round: `git diff 982ea64..96bfbf1`

Round 1 found two bugs (core-version fallback on retirement; `no_qualifying_members` dropped rejections and hashed `[]`). Both are fixed in SQL, not just claimed. Issue 5 (universe_key lock) and Issue 8 (nit) are also fixed. Suggestions 3, 4, 6, 7 were deferred/wontfix this WU and were not re-litigated; no regression from the hardening commit.

Verified by reading `0026_coverage_fitness_admission.sql`, `wu24_coverage_fitness_probe.sql`, and the acceptance-script/evidence JSON updates. The implementer reports the acceptance script passed after these fixes.

## Highs checked

| # | Item | Result |
|---|---|---|
| 1 | Point-in-time leaks | **OK.** Mapping reconstruction matches hardened WU-23. Listings, aliases, EOD, GICS, and core defs gate `receipt_time <= as_of`. Late GICS probed. Retired core no longer falls back to v1 (Issue 1 fixed). GICS latest-belief / no `valid_to` remains deferred (Issue 6). |
| 2 | Predictive inputs in fitness | **OK.** Unchanged. Five-component weighted sum; twins ignore returns; `last_close` is score_facts only; close enters ADV only. |
| 3 | Experimental indicators as Core / bound into the universe | **OK.** `indicator_kind = 'core'` then latest PIT version, then declared-only. Experimental is facts-only. Retirement does not resurrect v1. `experimental_excluded` is derived from bound ids. |
| 4 | First seed >40, below floor, enhanced-risk, skip RC, skip obligations | **OK.** Complete path unchanged. Zero-admit is now **complete** with `admitted_count = 0`, profile resolved, every scored rejection persisted (Issue 2 fixed). |
| 5 | Unique-constraint / audit event_id collisions | **OK.** Unchanged. UUIDs per run; duplicates raise before insert. Zero-admit is a different trading date so it does not collide with the 40-admit seed. |
| 6 | Failed precondition rows consuming the one-seed slot | **OK.** Unapproved / incomplete fitness / future as_of still RAISE before insert. Empty pool still fails at fitness. Zero-admit no longer inserts a failed universe; it completes with stored rejections (Issue 2 fixed). |
| 7 | PL/pgSQL RETURNS TABLE ambiguity | **OK.** Unchanged. |
| 8 | Race on version allocation or unique (policy, date) | **OK.** `universe_key` lock (seed 26025) then policy+date first-seed lock (26024). Consecutive `max(version)+1` is serialized on the version unique; one-seed unique remains serialized. |
| 9 | Digest timezone dependence | **OK.** Unchanged. Zero-admit now hashes the actual decision set, not `[]`. |
| 10 | Direct INSERT bypassing workflow | **OK.** Unchanged. |
| 11 | Sector ceiling vs running fraction | **OK.** Unchanged. Target-40 denominator. |
| 12 | Comments | **OK.** Returns/ADV comment corrected; `experimental_excluded` no longer a literal. |

## Issues

### Issue 1 -- Severity: bug
- **File**: db/migrations/0026_coverage_fitness_admission.sql:103
- **Description**: (Round 1) `coverage_core_indicator_ids_as_of` applied `lifecycle = 'declared'` in `WHERE` before `DISTINCT ON` latest version, so retiring core v2 silently rebound v1.
- **Suggestion**: Select the latest PIT version per key first, then keep it only if declared. Probe v1-at-old-as_of and empty-after-v2-retirement.
- **Status**: fixed

  Round 2 verification: inner `DISTINCT ON (indicator_key) ... ORDER BY version DESC` is restricted only by `indicator_kind = 'core'` plus `effective_from`/`receipt_time` <= as_of. Outer `WHERE` then requires as-of lifecycle `declared`. No predecessor fallback.

  Probe `retired_core_does_not_fallback`: after appending core v2 (successor_of v1, `effective_from = clock_timestamp()`) and `record_indicator_definition_lifecycle(..., 'retired', ...)`, `coverage_core_indicator_ids_as_of(v_fitness.as_of_at) = ARRAY[v1]` and `coverage_core_indicator_ids_as_of(clock_timestamp()) = '{}'` with neither v1 nor v2 present. First-seed binds cores via this function, so a later fitness as_of cannot resurrect v1.

### Issue 2 -- Severity: bug
- **File**: db/migrations/0026_coverage_fitness_admission.sql:1163
- **Description**: (Round 1) `no_qualifying_members` set `failure_reason` after staging decisions, skipped the digest loop and membership insert, hashed `'[]'`, inserted `admission_state = 'failed'` with NULL profile, and burned `UNIQUE (policy_version_id, trading_date, admission_kind)`.
- **Suggestion**: Persist every scored rejection when admitted_count is 0; complete with profile resolved rather than a failed empty digest.
- **Status**: fixed

  Round 2 verification: `failure_reason_value` is never assigned in `run_coverage_universe_first_seed`. The stage table is always digested (`ORDER BY security_id`) and, on insert, memberships are always written. `admission_state` is `complete` with `profile_resolution_id` set (CHECK requires that). `admitted_count = 0` is allowed (`>= 0` and `<= target_count`). Unapproved / incomplete fitness still RAISE before any universe row.

  Probe `zero_admit_persists_rejections`: extra 2026-08-24 bars for `nogics_a` and `otc_enh` only, so the 5-session calendar includes 8/24 and everyone else fails Discovery `insufficient_data`. Seed of that complete fitness run is `admission_state = complete`, `admitted_count = 0`, profile present, membership count = scored_count, no admitted rows, `nogics_a` has `below_quality_floor`, `otc_enh` has `enhanced_risk_gates_incomplete`. Different trading date from the 40-admit seed, version 2 of `coverage-universe`.

### Issue 3 -- Severity: suggestion
- **File**: db/migrations/0026_coverage_fitness_admission.sql:694
- **Description**: Observability is a global core-definition count plus session completeness. On a complete Discovery Pool that is a constant and does not rank per-name research/catalyst observability. Experimental defs remain excluded.
- **Suggestion**: Deferred this WU — observability here is the WU-26 bind seam, not WU-14 catalysts.
- **Status**: open

### Issue 4 -- Severity: suggestion
- **File**: db/migrations/0026_coverage_fitness_admission.sql:1005
- **Description**: First seed enforces tech absolute / ordinary sector caps against the target-40 denominator. It does not apply `correlation_cluster_max_fraction` or tech/energy preference as a post-quality tie-break. Cluster ceiling has no correlation evidence in this WU.
- **Suggestion**: Deferred this WU.
- **Status**: open

### Issue 5 -- Severity: suggestion
- **File**: db/migrations/0026_coverage_fitness_admission.sql:1138
- **Description**: (Round 1) Advisory lock covered the one-seed unique `(policy, date, first_seed)` but not `UNIQUE (universe_key, version)` allocation.
- **Suggestion**: Lock `universe_key` as well as the policy+date slot, `universe_key` first.
- **Status**: fixed

  Round 2 verification: `pg_advisory_xact_lock(hashtextextended(universe_key_value, 26025))` then the existing policy+date lock (26024), then `max(version)+1`. Consistent lock order avoids deadlock with the one-seed unique. No silent double insert on either unique.

### Issue 6 -- Severity: suggestion
- **File**: db/migrations/0026_coverage_fitness_admission.sql:483
- **Description**: GICS is latest-belief (`receipt_time DESC`, `valid_from` start only, no `valid_to`). Late receipts stay hidden (probed). Period-bounded restatements are not representable. Implementer model is intentional for this WU.
- **Suggestion**: Deferred this WU.
- **Status**: open

### Issue 7 -- Severity: suggestion
- **File**: db/migrations/0026_coverage_fitness_admission.sql:759
- **Description**: Quality-floor numeric cutoffs are literals in the scorer, not policy fields. Floor is still applied; below-floor names are never admitted. Pinning the number in WU-22 is out of scope.
- **Suggestion**: Deferred this WU.
- **Status**: open

### Issue 8 -- Severity: nit
- **File**: db/migrations/0026_coverage_fitness_admission.sql:670
- **Description**: (Round 1) Comment claimed close never entered a score; `'experimental_excluded'` was a literal `true`.
- **Suggestion**: Say returns never enter the score and close is ADV only. Derive `experimental_excluded` from bound ids.
- **Status**: fixed

  Round 2 verification: comment is `-- Returns never enter the score; close is used only as an ADV input.` `experimental_excluded` is `NOT EXISTS (unnest(core_ids) JOIN indicator_definition_version WHERE indicator_kind = 'experimental')`. Tautological while `coverage_core_indicator_ids_as_of` filters `kind = 'core'`, but it will flip if that filter regresses.

## Notes (not issues)

- First-seed `failure_reason_value` is now dead (always NULL). Failed universe rows can still exist in the schema; this WU no longer writes one. Empty discovery still fails at fitness. Not a bug.
- Zero-admit universe binds cores at that fitness `as_of` (after v2 retirement in the probe → empty bound set). Correct PIT; first 40-admit universe still binds v1.
- Weights 30/30/15/15/10, enhanced-risk fail-closed gates, 40 Research Candidates vs post-promotion 15/25, `clock_timestamp()` receipts, write-GUC + PUBLIC revoke: unchanged from round 1.
- Acceptance keys `retired_core_does_not_fallback` and `zero_admit_persists_rejections` are required in the script and present as true in `evidence/wu-24/coverage-universe-report.json`.
