# Thermo-nuclear review: WU-28 through WU-31

Range: `1143e26..7d77642` (`main`). PRs #104–#107, already merged. No BugBot or review comments on those PRs.

Security audit: clean (0 critical/high/medium/low). GUC, `SECURITY DEFINER` `search_path`, PUBLIC revokes, advisory locks, and stage-1 no-Live invariants hold.

Per-WU reviews before merge did not catch the cross-WU items below.

## Open bugs

### 1. High — tracer `now()` vs registry `clock_timestamp()` inverts WU-06 ordering

- **Files**: `backend/src/tracer.rs:285,317`; `db/migrations/0030_experiment_registry_preregistration.sql:269`; `scripts/wu06_tracer_test.sh:140-146`
- **What**: `run_tracer` is one transaction. Snapshot and evaluation stamp `receipt_time` with `now()` (transaction start). `register_experiment_preregistration` stamps with `clock_timestamp()` (wall clock at insert). After the snapshot insert, register time is later than `now()`, so stored preregistration `receipt_time` is **after** evaluation `receipt_time` even though INSERT order is preregistration then evaluation.
- **Breakage**: WU-06 proves “preregistration precedes result” with `p.receipt_time <= e.receipt_time`. That assertion fails on a post-0030 database. Unique `(experiment_key, spec_digest)` is not the cause (one prereg + two evaluations is intended).
- **Fix**: Stamp tracer snapshot and evaluation with `clock_timestamp()`, or stamp the register function with `now()`.

### 2. Medium — unique `(experiment_key, spec_digest)` cannot apply to a volume that already ran WU-06 twice

- **File**: `db/migrations/0030_experiment_registry_preregistration.sql:15`
- **What**: Pre-WU-29, two tracer runs wrote two `wu06-tracer-toy` rows with the same digest. `CREATE UNIQUE INDEX` has no dedupe. Default compose `pgdata` persists. Append-only blocks DELETE. Fresh `-v` WU tests are fine.
- **Fix**: In the migration, collapse duplicates (re-point `evaluation_result`, disable mutation triggers, delete extras) before creating the unique index, or fail with an explicit message.

### 3. Medium — empty EOD calendar skips the “most recent 60 days” check

- **File**: `db/migrations/0031_release_holdout_custody.sql:305`
- **What**: Suffix check runs only when `cardinality(calendar) > 0`. 1–59 visible sessions fail closed; 0 visible sessions accept any strictly increasing ≥60-date list. WU-30 probe never inserts EOD, so it only exercises the empty path. Later EOD backfill with `available_at`/`receipt_time` ≤ original as_of cannot unseal the invented window.
- **Fix**: Fail closed on empty/short calendar, same as the 1–59 branch. Seed the probe with ≥60 EOD sessions.

### 4. Medium — Holm `m` is observed p-values, not declared family size

- **File**: `db/migrations/0032_evidence_budgets_multiplicity.sql:624`
- **What**: Issue #42 asks Holm across the declared finite family. Implementation uses the count of members whose latest trial has a non-null `p_value`. A result-bearing trial can omit `p_value`, spend budget, and drop out of Holm (`m=1` on 0.04 rejects; honest two-member Holm on `[0.04, 0.80]` does not). Interim correction before all members have p-values is optional stopping without an alpha-spending plan.
- **Fix**: Set `m` to declared family size (or shared `family_trials`). Treat missing p-values as 1. Require non-null `p_value` on result-bearing outcomes.

## Suggestions (not bugs)

- Unique `(predecessor_stage_record_id) WHERE NOT NULL` on experimental lineage, matching preregistration `successor_of`.
- WU-30 combined TRUNCATE cannot isolate one table’s trigger (FK). WU-31 already split this.

## Not bugs (traced)

- WU-06 second tracer run identity: one prereg, two snapshots, two evaluations. Script does not count prereg rows.
- Completeness uses `IS DISTINCT FROM` (no `NOT IN` fail-open).
- Chain-tip stage/prereg lookup, not `now()`/`uuid` order.
- Digest domain `market-mate-preregistration-v1|` + `spec::text` unchanged.
- `strategy_eligible` stays experimental; no Live/Trade Eligible leak.
- Exhaustion `RETURN NULL` after writing refusal: no new trial; `PERFORM` cannot spend budget.
- Holm vector `[0.04, 0.01] → [0.04, 0.02]`; Bonferroni only when every member preregisters it.
- Owner-role GUC bypass is issue #97 / migration 0009; not a new finding.
