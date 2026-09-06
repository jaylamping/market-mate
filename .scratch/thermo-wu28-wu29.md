# WU-28 / WU-29 thermo-nuclear review

**Round 1: 2 open bugs (1 high, 1 medium).**

Repo: `main` @ `7d77642`
Base: `1143e26` (WU-27 already on main; WU-27 re-read only as a callee)
Range: `1143e26..7d77642`, files listed in the prompt plus traced callers (`scripts/wu06_tracer_test.sh`, `db/migrations/0005_tracer_contracts.sql`, `core_indicator_definition_for_compute`).

Issue #97 owner-role GUC bypass is the same stage-1 boundary as `0009_evidence_guard_hardening.sql` and is **not** re-reported. Isolated-probe expected heads (`wu28` = 29, `wu29` = 30) are standing WU-N snapshots and are **not** reported as breakage at later heads.

## Highs checked

| # | Item | Result |
|---|---|---|
| 1 | `jsonb_typeof(...) NOT IN (...)` fail-open on absent keys | **OK.** Both completeness functions use `IS DISTINCT FROM` (or an `ELSE RETURN false` for `estimators`). `jsonb_typeof(NULL) IS DISTINCT FROM 'string'` is true, so missing keys fail closed. |
| 2 | Chain-tip current stage vs `now()` / UUID order | **OK.** `experimental_indicator_current_stage`, `experimental_indicator_latest_stage_record`, `current_experimental_indicator_stage`, and `experiment_preregistration_tip` all use `NOT EXISTS (later.predecessor / later.successor_of = this id)`, not receipt time. |
| 3 | Digest still `market-mate-preregistration-v1\|` + `spec::text` | **OK.** `0005` CHECK unchanged. `register_experiment_preregistration` hashes the same string (`0030:211-213`). WU-06 and WU-29 probes verify it. |
| 4 | Unique `(experiment_key, spec_digest)` vs second WU-06 tracer run | **OK for identity.** Second `register_experiment_preregistration('wu06-tracer-toy', same spec, NULL)` returns the existing row. WU-06 never counts preregistration rows; two snapshots + two evaluations on one registration still satisfy the script **except** High #5. |
| 5 | WU-06 `receipt_time` ordering after the tracer switched to the register function | **BUG.** See Issue 1. |
| 6 | Unique index create vs pre-WU-29 duplicate tracer rows | **BUG.** See Issue 2. |
| 7 | Root unique `WHERE successor_of IS NULL` + unique `successor_of` | **OK.** One root per key; one child per parent; tip `LIMIT 1` is deterministic on the write path. Self-successor CHECK present. |
| 8 | Post-hoc without `successor_of` / stale tip / cross-`experiment_key` | **OK.** Function raises before insert. Probe covers all three. |
| 9 | Original row mutates / results move onto the successor | **OK.** Append-only mutation guard + probe `original_never_mutates` / `result_stays_on_original`. |
| 10 | Incomplete WU-29 specs can still be inserted | **OK.** Completeness is checked inside `register_experiment_preregistration` before the GUC is armed. Direct INSERT is GUC-blocked. |
| 11 | WU-28 incomplete probes retargeted off WU-29-required keys | **OK.** Incomplete row is `v_spec - 'rationale'`. Omit loop is `horizon` / `universe` / `promotion_gate` / `target` / `indicator_key`. Those inserts are WU-29-complete and WU-28-incomplete. |
| 12 | WU-28 promotion still uses `experimental_preregistration_spec_is_complete` (superset) | **OK as a stricter document.** WU-28-complete ⇒ WU-29-complete for primary key names. WU-28 does not honor WU-29 aliases (`window`/`estimator`/`budget`/`multiplicity`) and rejects `estimators`/`multiplicity_plan` object/string shapes that WU-29 accepts. Intended split (tracer aliases vs experimental promotion keys), not a bypass. |
| 13 | Experimental `strategy_eligible` becomes Core or grants Live | **OK.** Kind is immutable (WU-26). `core_indicator_definition_for_compute` still refuses experimental keys. No Live stage exists. Probe covers both pre- and post-spine Core exclusion. |
| 14 | Direct INSERT / PUBLIC EXECUTE | **OK.** GUC insert guards + `REVOKE ALL … FROM PUBLIC` on the write functions and DML. Owner-role GUC arm is #97, unchanged. |
| 15 | Advisory lock not on the uniqueness key | **OK.** Register locks `hashtextextended(experiment_key, 30023)` before the existing/tip read. Experimental register/advance lock definition then registration, matching the unique indexes. |
| 16 | `SECURITY DEFINER` without `search_path` / GUC leak on error | **OK.** `SET search_path = pg_catalog, public`. Write flag is transaction-local and cleared on `WHEN OTHERS` and on the success path before `append_audit_event`. |
| 17 | Tracer still raw-inserting preregistration after the GUC | **OK.** `tracer.rs` calls `register_experiment_preregistration`. Toy spec gained `budget` so WU-29 completeness passes. Group sizes are read from the spec. |
| 18 | Probe `WHEN OTHERS` swallowing `probe corrupted` | **OK.** Re-raise unless the isolated `SQLERRM` matches. |
| 19 | Combined TRUNCATE isolating the wrong table’s trigger | **Suggestion / standing.** Same #97 limitation as prior WU-28 Issue 4 / WU-29 Issue 2. Not re-opened as a bug. |
| 20 | Stage skip / reverse / bound registration vs foreign spec | **OK.** Legal-transition CHECK + unique `(definition_version_id, to_stage)`. Reverse is `strategy_eligible -> paper_eligible` after the spine. Advance rebinds the register-time registration, not the caller’s manifest `registration_id`. |
| 21 | Lineage predecessor JSON null vs absent vs stale | **OK.** Key must be present; SQL NULL requires JSON `null`; advance requires the current tip’s `stage_record_id`. |
| 22 | Comments that narrate WHAT | **OK.** File headers only. |

## Issues

### Issue 1 -- Severity: high
- **File**: backend/src/tracer.rs:317
- **Description**: `run_tracer` opens a single transaction (`tracer.rs:259-263`). Snapshot and evaluation rows still stamp `receipt_time` with `now()` (`tracer.rs:285`, `tracer.rs:317`), which is the transaction start. `register_experiment_preregistration` stamps preregistration `receipt_time` with `clock_timestamp()` (`0030_experiment_registry_preregistration.sql:269`). Wall-clock at the register INSERT is strictly later than transaction start after the snapshot insert and the function’s lock/lookup work, so stored `experiment_preregistration.receipt_time` is later than `evaluation_result.receipt_time` even though the INSERT order is preregistration then evaluation. WU-06 proves “preregistration precedes result” with `p.receipt_time <= e.receipt_time` (`scripts/wu06_tracer_test.sh:140-146`) and fails that assertion. Unique `(experiment_key, spec_digest)` does **not** cause this: the second tracer run is a legitimate one-prereg / two-evaluation identity; the ordering predicate is what breaks. Pre-WU-29 both inserts used `now()` and compared equal.
- **Suggestion**: Stamp tracer snapshot and evaluation `receipt_time` with `clock_timestamp()` (preserving wall-clock order inside the transaction), or stamp the register INSERT with `now()` so it stays paired with the tracer’s evaluation row. Keep the domain string `market-mate-preregistration-v1|` + `spec::text`.
- **Status**: open

### Issue 2 -- Severity: medium
- **File**: db/migrations/0030_experiment_registry_preregistration.sql:15
- **Description**: `CREATE UNIQUE INDEX experiment_preregistration_content_uq ON experiment_preregistration (experiment_key, spec_digest)` is applied with no dedupe. WU-06’s documented acceptance is two tracer runs of the identical spec (`scripts/wu06_tracer_test.sh:85-89`). Before this unique existed that wrote two `wu06-tracer-toy` rows with the same digest. Default `docker-compose.yml` keeps `pgdata`. Applying 0030 onto that volume fail-closes the migrator. Append-only UPDATE/DELETE/TRUNCATE on `experiment_preregistration` (`0005` + `0009`) cannot remove the duplicates through the workflow. Fresh `-v` WU tests and post-0030 tracer runs are fine (second run is idempotent).
- **Suggestion**: Before creating the unique, re-point `evaluation_result.registration_id` to one survivor per `(experiment_key, spec_digest)` and delete the extras with the mutation trigger disabled inside the migration transaction, or fail with an explicit “duplicate preregistration rows must be collapsed” message. Do not rely on a later DELETE through the table.
- **Status**: open

### Issue 3 -- Severity: suggestion
- **File**: db/migrations/0029_experimental_observation_states.sql:180
- **Description**: WU-29 added `experiment_preregistration_successor_uq` so a GUC-armed INSERT cannot fork a preregistration parent (`0030:20-22`). Experimental lineage has the matching unique only for `predecessor_stage_record_id IS NULL` (`0029:180-185`). A GUC-armed INSERT can attach two children to the same `stage_record_id`. `experimental_indicator_current_stage` / `experimental_indicator_latest_stage_record` then `LIMIT 1` with no `ORDER BY` (`0029:266-275`, `0029:301-309`). The workflow functions hold the definition advisory lock and insert one legal next `to_stage`, so this is not reachable without arming the write GUC (issue #97).
- **Suggestion**: Add `UNIQUE (predecessor_stage_record_id) WHERE predecessor_stage_record_id IS NOT NULL`, parallel to `experiment_preregistration_successor_uq`.
- **Status**: open

## Notes (not issues)

- WU-06 second tracer run after 0030: one `wu06-tracer-toy` registration, two `research_snapshot` rows, two `evaluation_result` rows, matching spec/result digests, extra `research.experiment_preregistration_registered` audit event only on the first run. Identity assertions in `wu06_tracer_test.sh` hold; only the `receipt_time` predicate does not.
- WU-28 evidence JSON is the head-29 snapshot (pre-retarget gates). WU-29 updated the WU-28 probe/script and left that artifact frozen. Standing isolated-probe discipline; not recaptured.
- Combined TRUNCATE probes remain a #97 limitation (FK forces a multi-table statement; any table’s append-only trigger satisfies `LIKE '%append-only%'`).
- No new env vars, ports, or mandatory setup. `REVOKE`/`SECURITY DEFINER`/`search_path` match 0009/0028 siblings.
