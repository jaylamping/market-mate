# WU-29 thermo-nuclear review

**Round 2: 0 open bugs.**

Branch: `jl/wu-29-experiment-registry-preregistration` (HEAD = `main` b6f05e4; work is uncommitted)
Base: `main` (b6f05e4)
Diff this round: working tree vs round 1. Evidence checksum `397cc3c5…` matches the working-tree `0030_experiment_registry_preregistration.sql` (changed from round 1 `8f07928d…` with the successor unique). Bring-up log ends `WU-29 COMPLETE`. Tracer unit tests include `toy_evaluation_reads_group_sizes_from_spec`.

Round 1 found 0 bugs and three suggestions (unique `successor_of`; combined TRUNCATE isolation; toy-eval tests never varying group sizes). Issues 1 and 3 are fixed in SQL/tests, not just claimed. Issue 2 remains a standing limitation, not a bug, and is not re-opened.

Verified by reading `experiment_preregistration_successor_uq`, `toy_evaluation_reads_group_sizes_from_spec`, `git status` on `evidence/wu-28/experimental-indicator-record.json`, the acceptance log, and evidence JSON.

## Highs checked

| # | Item | Result |
|---|---|---|
| 1 | `jsonb_typeof NOT IN` fail-open on absent keys | **OK.** Unchanged. |
| 2 | `now()` vs `clock_timestamp()` / UUID order for tip | **OK.** Unchanged. |
| 3 | Direct INSERT bypassing GUC | **OK.** Unchanged. |
| 4 | Digest domain vs WU-06 CHECK | **OK.** Unchanged. |
| 5 | Post-hoc without `successor_of` silently overwriting / second root | **OK.** Unchanged. |
| 6 | Original spec mutates on successor | **OK.** Unchanged. |
| 7 | Successor of a non-tip / other `experiment_key` | **OK.** Unchanged. |
| 8 | Unique `(experiment_key, spec_digest)` vs idempotent return vs fork | **OK.** Issue 1 fixed: catalog unique on `successor_of` now matches unique-root. Register path unchanged. |
| 9 | Advisory lock not on `experiment_key` | **OK.** Unchanged. |
| 10 | Probe `WHEN OTHERS` swallowing `probe corrupted` | **OK.** Unchanged. |
| 11 | TRUNCATE FK masking append-only | **Suggestion** — Issue 2 limitation stands; not a bug. |
| 12 | Comments that narrate WHAT / unused variables | **OK.** Unchanged. |
| 13 | Public EXECUTE left on `register_experiment_preregistration` | **OK.** Unchanged. |
| 14 | Tracer still raw-inserting after GUC | **OK.** Unchanged. |
| 15 | `evaluate_toy_spec` still ignoring spec groups (#97) | **OK.** Issue 3 fixed: non-default group sizes and invalid sizes are now asserted. |
| 16 | WU-28 probe still raw-inserting incomplete WU-29 specs | **OK.** Unchanged. |
| 17 | Alias window/estimator/testing_budget/multiplicity fail-open or fail-closed | **OK.** Unchanged. |
| 18 | `CREATE OR REPLACE` dropping `SECURITY DEFINER` | **OK.** Unchanged. |
| 19 | Self `successor_of` | **OK.** Unchanged. |
| 20 | Results vs mutation vs successor | **OK.** Unchanged. |

## Issues

### Issue 1 -- Severity: suggestion
- **File**: db/migrations/0030_experiment_registry_preregistration.sql:20
- **Description**: (Round 1) Linear history was enforced only inside `register_experiment_preregistration`. `successor_of` had a non-unique index while roots had `experiment_preregistration_root_uq`. A GUC-armed `INSERT` could attach two different specs to the same parent; `experiment_preregistration_tip` then `LIMIT 1` with no `ORDER BY`.
- **Suggestion**: Add `UNIQUE (successor_of)` where `successor_of IS NOT NULL`.
- **Status**: fixed

  Round 2 verification: `CREATE UNIQUE INDEX experiment_preregistration_successor_uq ON experiment_preregistration (successor_of) WHERE successor_of IS NOT NULL` (`0030:20-22`). The old non-unique `successor_idx` is gone. Roots remain covered by `experiment_preregistration_root_uq`. The unique still supports the tip lookup `later.successor_of = r.registration_id`. Linear chain A←B←C uses distinct parent ids, so a valid successor is not blocked. Register still rejects a non-tip `successor_of` before insert; the unique is the catalog backstop for GUC-armed forks. Evidence checksum `397cc3c5…` includes this index.

### Issue 2 -- Severity: suggestion
- **File**: db/fixtures/wu29_experiment_registry_probe.sql:237
- **Description**: Combined `TRUNCATE experiment_preregistration, evaluation_result, experimental_indicator_lineage, experimental_indicator_stage` can satisfy `SQLERRM LIKE '%append-only%'` from any of the four `BEFORE TRUNCATE` triggers. PostgreSQL rejects single-table `TRUNCATE` of a referenced table before triggers fire. UPDATE and DELETE on this table remain isolated.
- **Suggestion**: Keep the combined statement. Do not claim the probe isolates *this* table’s truncate trigger.
- **Status**: open

  Round 2 verification: combined TRUNCATE is unchanged. Not re-opened as a bug. Limitation stands (same as WU-28 Issue 4 / issue #97 standing discipline).

### Issue 3 -- Severity: suggestion
- **File**: backend/src/tracer.rs:451
- **Description**: (Round 1) `evaluate_toy_spec` read group sizes from the spec, but every unit test used the default toy spec (`top: 2`, `bottom: 2`). A regression that hardcodes `.take(2)` / `.skip(len - 2)` would still pass.
- **Suggestion**: Assert a non-default `(top, bottom)` changes group membership, and that invalid sizes return `Err`.
- **Status**: fixed

  Round 2 verification: `toy_evaluation_reads_group_sizes_from_spec` (`tracer.rs:451-467`) sets `top = 1`, `bottom = 1` and requires each group’s `symbols` length to be 1 (hardcoded 2 would fail). `top = 0` and `top = 3, bottom = 3` (3+3 > 5 symbols) both `is_err()`, matching `top_n == 0 || bottom_n == 0 || top_n + bottom_n > surprise_by_symbol.len()` (`tracer.rs:179-181`).

## Notes (not issues)

- Round-1 notes on WU-29 vs WU-28 completeness, omit-key vs empty-value probes, unused `PREREGISTRATION_DOMAIN`, and the owner-role GUC boundary are unchanged and not re-litigated.
- `evidence/wu-28/experimental-indicator-record.json` is present and matches HEAD (head 29, checksum `243af7d7…`). It is not deleted in the working tree. The WU-28 script still expects migration head 29; the retargeted probe SQL is what must stay compatible with head 30.
- No new env vars, ports, or mandatory setup. No new bugs from the successor unique or the group-size test. Fingerprint moved `fa954e5c…` → `931fa44d…` with the unique index, as expected.
