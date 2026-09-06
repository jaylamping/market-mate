# WU-30 thermo-nuclear review

**Round 2: 0 open bugs.**

Branch: `jl/wu-30-release-holdout-custody` (HEAD = `main` 937574d; work is untracked)
Base: `main` @ 937574d
Diff this round: working tree vs round 1. Evidence checksum `ed7706f5…` matches the working-tree `0031_release_holdout_custody.sql` (changed from round 1 `6e859d12…` with the required-key check). Fingerprint `7cf922d5…` matches the live WU-30 database. Bring-up log ends `WU-30 COMPLETE`.

Round 1 found 0 bugs and two suggestions (exact estimator key-set; combined TRUNCATE isolation). Issue 1 is fixed in SQL/probe, not just claimed. Issue 2 remains a standing limitation, not a bug, and is not re-opened.

Verified by reading `release_holdout_result_matches_registration`, the omit-one-estimator probe, the extra-key probe (still both required keys plus `secret_metric`), the acceptance-script key loop and `jq -e`, and evidence JSON. Confirmed on the WU-30 database: two-key exact match is true; omitting `eis` or `lcb` is false; extra key on a complete set is false; object-estimators with a missing result key is now false (was true in round 1).

## Highs checked

| # | Item | Result |
|---|---|---|
| 1 | `jsonb_typeof NOT IN` fail-open on absent keys; completeness/result matching MUST use `IS DISTINCT FROM` | **OK.** Issue 1 fixed (see below). Typeof still `IS DISTINCT FROM 'object'`. Matching now requires every allowed name via `result_value ? a.name`. |
| 2 | `now()` vs `clock_timestamp()` / UUID order for “current” / consumed | **OK.** Unchanged. |
| 3 | Direct INSERT bypassing GUC | **OK.** Unchanged. |
| 4 | Digest timezone dependence | **OK.** Unchanged. Checksum move is the matching function only. |
| 5 | Second evaluation returning existing (idempotent) instead of refusing | **OK.** Unchanged. Happy-path evals now pass both estimator keys. |
| 6 | Failed evaluation not consuming | **OK.** Unchanged. Failed eval result is now `block_bootstrap_lcb` + `eis`. |
| 7 | Extra result keys (optimizer leakage) accepted | **OK.** Extra-key probe still present and now includes both required keys plus `secret_metric`. |
| 8 | Extra-key refusal that still inserts/consumes | **OK.** Unchanged extra_key_does_not_consume; missing-key path is a new sibling that also must not consume. |
| 9 | Unconsumed second seal of a different window succeeding | **OK.** Unchanged. |
| 10 | Seal of <60 days, unsorted, duplicates, NULLs | **OK.** Unchanged. |
| 11 | Last trading date after as_of / future as_of | **OK.** Unchanged. |
| 12 | When EOD calendar exists, sealing a non-suffix window | **Untested, SQL looks right.** Unchanged. Empty calendar; do not invent a bug. |
| 13 | Advisory lock not on the uniqueness / consumption key | **OK.** Unchanged. |
| 14 | Probe `WHEN OTHERS` swallowing `probe corrupted` | **OK.** Missing-key block raises `probe corrupted: incomplete estimator set was accepted` if accepted; that does not match `%only preregistered estimator keys%` and re-raises. |
| 15 | TRUNCATE FK masking (evaluation FKs to seal) | **Suggestion** — Issue 2 limitation stands; not a bug. |
| 16 | Comments that narrate WHAT / unused variables | **OK.** No new comments or unused vars. Presence check is uncommented SQL. |
| 17 | Public EXECUTE left on write functions | **OK.** Unchanged. |
| 18 | Idempotent reseal unconsuming a consumed holdout | **OK.** Unchanged. |
| 19 | `UNIQUE(holdout_id)` vs function-level consume check race without lock | **OK.** Unchanged. Matching still runs before the lock; missing keys never reach INSERT. |
| 20 | CHECK digest vs computed digest mismatch | **OK.** Unchanged. |
| 21 | Array subscript / cardinality bugs | **OK.** Unchanged. `unnest(allowed) AS a(name)` is a set of text names, not dates. |
| 22 | `release_holdout_estimator_names` column/alias bugs (`jsonb_object_keys` table alias) | **OK.** New `FROM unnest(allowed) AS a(name)` / `result_value ? a.name` live-tested (exact two true, omit false). Extra-key `jsonb_object_keys` alias unchanged. |

## Issues

### Issue 1 -- Severity: suggestion
- **File**: db/migrations/0031_release_holdout_custody.sql:89
- **Description**: (Round 1) `release_holdout_result_matches_registration` rejected extra keys, then `RETURN true`. It never required every name from `release_holdout_estimator_names` to appear in `result`. A two-estimator registration with only `block_bootstrap_lcb` in the result matched and consumed. Probe registered a single estimator.
- **Suggestion**: After the extra-key `EXISTS`, also require every `allowed` name to be present (`jsonb_exists` / `result_value ? name`, or symmetric set equality). Probe two estimators and omit one; that path must raise and must not consume. Keep extra-key-does-not-consume.
- **Status**: fixed

  Round 2 verification: after the extra-key `EXISTS`, a second `EXISTS` walks `unnest(allowed) AS a(name)` and returns false when `NOT (result_value ? a.name)` (`0031:96-102`). Probe spec is now `jsonb_build_array('block_bootstrap_lcb', 'eis')` (`wu30_release_holdout_probe.sql:38`). Omit-`eis` evaluate raises `probe corrupted: incomplete estimator set was accepted` if accepted; the isolated path requires `SQLERRM LIKE '%only preregistered estimator keys%'` then `missing_estimator_key_blocked` / `missing_key_does_not_consume` (`probe.sql:169-183`). Extra-key probe still sends both required keys plus `secret_metric` (`probe.sql:129-143`). Happy-path failed eval and second-seal eval both include `eis`. Acceptance key loop and `jq -e` require the new gates. Live: `exact_two` true; `missing_eis` / `missing_lcb` / `extra_plus_complete` / `object_estimators_missing` false. Evidence checksum `ed7706f5…` includes this function.

### Issue 2 -- Severity: suggestion
- **File**: db/fixtures/wu30_release_holdout_probe.sql:256
- **Description**: (Round 1) Combined `TRUNCATE release_holdout_evaluation, release_holdout_seal` can satisfy `SQLERRM LIKE '%append-only%'` from either table’s `BEFORE TRUNCATE` trigger. PostgreSQL rejects single-table `TRUNCATE` of seal before triggers fire because evaluation FKs to it. UPDATE and DELETE remain isolated.
- **Suggestion**: Keep the combined statement. Do not claim the probe isolates *this* table’s truncate trigger.
- **Status**: open

  Round 2 verification: combined TRUNCATE is unchanged (now `probe.sql:256` after the missing-key block). Not re-opened as a bug. Limitation stands (same as WU-29 Issue 2 / WU-28 Issue 4).

## Notes (not issues)

- Round-1 notes on the empty EOD calendar suffix path, same-digest reseal after consume, `UNIQUE(first, last)`, and the owner-role GUC boundary are unchanged and not re-litigated. GUC-armed INSERT still has no CHECK that result keys equal the registration spec; the workflow function now refuses both extra and missing keys.
- `jsonb ?` tests key presence, not a non-null value. `{"eis": null}` still matches; values remain uninterpreted (gate_passed is caller-supplied). Out of WU-30 custody scope.
- The evaluate error string is still `must contain only preregistered estimator keys` for both extra and missing keys. Fail-closed; probe matches that substring. Not a consume bypass.
- No new env vars, ports, or mandatory setup. Head is still migration 31. Fingerprint moved `b5eccaf2…` → `7cf922d5…` with the matching rewrite, as expected.
