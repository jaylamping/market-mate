# WU-31 thermo-nuclear review

**Round 2: 0 open bugs.**

Branch: `jl/wu-31-evidence-budgets-multiplicity` (untracked working tree)
Base: `main` @ 6896c2c
Diff this round: working tree vs round 1. Evidence checksum `278b65d8…` matches the working-tree `0032_evidence_budgets_multiplicity.sql` (changed from round 1 `5f94cd25…` with the unused `adj` drop). Fingerprint `dbc02a69…` matches the live WU-31 database. Bring-up log ends `WU-31 COMPLETE`.

Round 1 found 0 bugs and two suggestions (unused `adj`; combined TRUNCATE isolation). Both are fixed in SQL/probe/acceptance, not just claimed. No new bugs from those edits.

Verified by reading `holm_adjusted_p`, the three single-table TRUNCATE blocks, the acceptance key loop and `jq -e`, and evidence JSON. Trigger messages are table-specific; LIKE patterns do not cross-match (`experiment_trial is append-only` is not a substring of `experiment_trial_refusal is append-only`).

## Highs checked

| # | Item | Result |
|---|---|---|
| 1 | `jsonb_typeof NOT IN` fail-open. Use `IS DISTINCT FROM` | **OK.** Unchanged. |
| 2 | Holm math wrong (sort, monotone max, `(m-k+1)`, map back). Vector `[0.04, 0.01]` must be `[0.04, 0.02]` | **OK.** Write-back is still `result[order_idx[i]] := running` after `greatest`/`least(1, p*(m-i+1))`. Dead `adj` store is gone. |
| 3 | Default is not Holm (string `family-wise error at 5%` must be holm; object method `none` must fail) | **OK.** Unchanged. |
| 4 | Different correction applying without preregistration | **OK.** Unchanged. |
| 5 | Conflicting methods in one family accepted | **OK.** Unchanged. |
| 6 | Exhausted budget still inserts a trial | **OK.** Unchanged. |
| 7 | Refusal not actually recorded (subtransaction rollback) | **OK.** Unchanged. |
| 8 | `PERFORM record_experiment_trial()` ignoring NULL on exhaustion | **OK.** Unchanged. Not a consume bypass. See notes. |
| 9 | Family split/rename via `successor_of` changing `experiment_family` | **OK.** Unchanged. Untested in the probe; SQL is the gate. |
| 10 | Members with different `family_trials` sharing a family | **OK.** Unchanged. Untested in the probe; SQL is the gate. |
| 11 | Digest TZ / `convert_to UTF8` | **OK.** Unchanged. Checksum move is the Holm function only. |
| 12 | GUC bypass / direct `INSERT` | **OK.** Unchanged. |
| 13 | Probe `WHEN OTHERS` swallowing `probe corrupted` | **OK.** Truncate success would raise `probe corrupted: … was truncatable`, which does not `LIKE` `%… is append-only%`, so it re-raises. |
| 14 | `TRUNCATE` FK masking; combined `TRUNCATE` | **OK.** Issue 2 fixed (see below). |
| 15 | Advisory lock not on `family_key` | **OK.** Unchanged. |
| 16 | `p_value` outside `[0,1]`; NULL p_value counted for Holm incorrectly | **OK.** Unchanged. |
| 17 | Public `EXECUTE` left on write functions | **OK.** Unchanged. |
| 18 | Comments that narrate WHAT / unused variables | **OK.** Issue 1 fixed. No new comments. |
| 19 | `experiment_trial_digest` `CHECK` vs function order | **OK.** Unchanged. |
| 20 | PL/pgSQL `SELECT INTO` predecessor.`successor_of` overwrite | **OK.** Unchanged. |
| 21 | Holm vs Bonferroni probe asserting the wrong array index after `ORDER BY receipt_time` | **OK.** Unchanged. |
| 22 | Alpha default 0.05; mismatched alpha across members | **OK.** Unchanged. |

## Issues

### Issue 1 -- Severity: suggestion
- **File**: db/migrations/0032_evidence_budgets_multiplicity.sql:142
- **Description**: (Round 1) `holm_adjusted_p` declared `adj numeric[]`, filled it, and assigned `adj[i] := running` in the same loop that wrote `result[order_idx[i]]`. Only `result` was returned.
- **Suggestion**: Drop `adj`. Keep `running` and the write-back into `result`.
- **Status**: fixed

  Round 2 verification: `adj` is absent. DECLARE is `order_idx`, `result`, `running`, `tmp` (`0032:141-144`). After the sort, only `result := array_fill(...)` then `result[order_idx[i]] := running` (`0032:169-173`). Holm vector probe is still `[0.04, 0.01] → [0.04, 0.02]`. Evidence checksum `278b65d8…` includes this function.

### Issue 2 -- Severity: suggestion
- **File**: db/fixtures/wu31_evidence_budgets_probe.sql:261
- **Description**: (Round 1) Combined `TRUNCATE experiment_trial, experiment_trial_refusal, experiment_family_correction` could satisfy `SQLERRM LIKE '%append-only%'` from any of the three `BEFORE TRUNCATE` triggers. No FKs among the three tables, so single-table `TRUNCATE` was available.
- **Suggestion**: Three separate `TRUNCATE` blocks, each requiring `%append-only%`. Do not claim the combined statement isolates one table’s trigger.
- **Status**: fixed

  Round 2 verification: three isolated blocks (`probe.sql:260-285`). Each `TRUNCATE`s one table and requires the table-specific message: `%experiment_trial is append-only%`, `%experiment_trial_refusal is append-only%`, `%experiment_family_correction is append-only%` (`0032:283`, `296`, `309`). Those strings do not cross-match. `probe corrupted: … was truncatable` does not match and re-raises. Acceptance key loop, `guard_payload`, report JSON, and `jq -e` require `trial_truncate_blocked` / `refusal_truncate_blocked` / `correction_truncate_blocked`; `budget_truncate_blocked` is gone. Evidence JSON has all three true.

## Notes (not issues)

- Round-1 notes on `RETURN NULL` (not a consume bypass), Holm `m` as observed non-null p-values, outcome-bearing `count(*)`, successor family immutability, string `none` → Holm, and the owner-role GUC boundary are unchanged and not re-litigated.
- No new env vars, ports, or mandatory setup. Head is still migration 32. Fingerprint moved `45e28755…` → `dbc02a69…` with the Holm rewrite, as expected.
