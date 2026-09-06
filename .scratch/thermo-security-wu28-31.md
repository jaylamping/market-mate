# Security Audit: WU-28 through WU-31 (1143e26..7d77642)

Scope: added/modified code only on `main` @ `7d77642` versus `1143e26`. Files: `db/migrations/0029_experimental_observation_states.sql`, `0030_experiment_registry_preregistration.sql`, `0031_release_holdout_custody.sql`, `0032_evidence_budgets_multiplicity.sql`, `backend/src/tracer.rs`, and the related WU-28..31 probes/scripts.

Threat model: Local Research, single connecting role (`mm`) owns the catalog. Issue #97 (GUC is an accidental/unprivileged write guard, not a durable privilege split) is unchanged by this diff and is **not** re-reported. Owner-role `set_config` bypass is the same stage-1 pattern as `0009_evidence_guard_hardening.sql`.

## Summary

Overall risk assessment: **clean**.

No exploitable injection, authorization leftover, privilege-grant regression, holdout-reuse race, digest mismatch, feature leak, or credential-shaped config was found in this range. Workflow write functions pin `search_path`, arm/disarm transaction-local GUCs in exception handlers, take advisory xact locks on the uniqueness/consumption keys, and `REVOKE ALL … FROM PUBLIC`. Unique indexes backstop the locks. `strategy_eligible` cannot become Core and does not grant Live, Trade Eligible, or order authority.

## Findings

None.

## Checks performed (negative results)

### Injection

- No `EXECUTE`/`format()` dynamic SQL in 0029–0032. Callers bind `jsonb`/`uuid`/`text`/`date[]` arguments; hashes use `digest(...)` / `convert_to(..., 'UTF8')`, not SQL concatenation that is later executed.
- Every `SECURITY DEFINER` function sets `search_path = pg_catalog, public` (0029:374, 0029:526, 0030:184, 0031:269, 0031:391, 0032:397, 0032:580). Trigger and helper functions do the same.
- GUC names are literals (`market_mate.*_write`). `set_config(..., true)` is transaction-local. Write flags are cleared on both the success path and `WHEN OTHERS` before re-raise, matching 0009 — no leftover-armed smuggle after a caught failure.

### Authorization / privilege

Write functions revoked from `PUBLIC`:

- 0029:684–688 `register_experimental_indicator_use`, `advance_experimental_indicator_stage`; `REVOKE INSERT, UPDATE, DELETE, TRUNCATE` on `experimental_indicator_lineage`, `experimental_indicator_stage`
- 0030:298–299 `register_experiment_preregistration`; same DML revoke on `experiment_preregistration`
- 0031:483–487 `seal_release_holdout`, `evaluate_release_holdout`; DML revoke on `release_holdout_seal`, `release_holdout_evaluation`
- 0032:699–703 `record_experiment_trial`, `compute_experiment_family_correction`; DML revoke on `experiment_trial`, `experiment_trial_refusal`, `experiment_family_correction`

No `GRANT EXECUTE` / `ALTER DEFAULT PRIVILEGES` in this diff. Helper functions remain `PUBLIC EXECUTE` but are not writers. This is not worse than 0009/0028 siblings.

Direct `INSERT` is blocked unless the matching GUC is `on` (row triggers). `UPDATE`/`DELETE`/`TRUNCATE` are blocked by statement triggers. Probes isolate those refusals.

### Race

| Operation | Lock | Catalog backstop |
|---|---|---|
| Preregistration / successor | `pg_advisory_xact_lock(hashtextextended(experiment_key, 30023))` (0030:215) | unique `(experiment_key, spec_digest)`, unique root, unique `successor_of` |
| Holdout seal | `hashtextextended('release-holdout', 31023)` (0031:324) | unique `seal_digest`, unique `(first_trading_date, last_trading_date)`, unconsumed-exists check under the lock |
| Holdout consume | `hashtextextended(holdout_id::text, 31024)` (0031:431) | `release_holdout_evaluation.holdout_id UNIQUE` |
| Family trial / Holm | `hashtextextended(family_key, 32023)` (0032:469, 0032:602) | consumed `count(*)` vs reserved budget under the lock |
| Experimental stages | locks on definition_version then registration (0029:438–441, 569–570, 600–601) | unique `(definition_version_id, to_stage)` plus register-only unique indexes |

Same-digest preregistration/holdout reseal is idempotent; a second evaluation of a consumed holdout raises `23505` (0031:437–440). Failed evaluations still insert and consume (0031:185–188 + probe). Extra/missing estimator keys raise before the consume insert (0031:89–102, 423–428).

### Integrity

- Append-only: `UPDATE`/`DELETE`/`TRUNCATE` raise `55000`. Digests are `CHECK`-bound to canonical `jsonb::text` / `convert_to` bytes (preregistration domain `market-mate-preregistration-v1|` matches 0005).
- Successor family change is refused when recording a trial (0032:452–466). Family members must share budget, correction method, and alpha (0032:476–493). Exhausted budget inserts a refusal and returns NULL rather than another trial (0032:496–530).
- Cross-`experiment_key` family membership is caller-chosen (`experiment_family` in the spec). That is the registry’s explicit grouping, not an in-band rename along a successor chain. Holm `m` is the count of non-null recorded p-values (0032:624–636); that is the implemented correction, not a lock/unique bypass.
- After a holdout is consumed, a *different* window may be sealed (0031:333–341; probe `new_seal_after_consumption`). Same-digest reseal returns the consumed row and does not unconsume it. When an EOD calendar exists, the sealed dates must equal the latest N sessions (0031:304–320). Empty-calendar skip is the same fail-open the WU-30 review already treated as a standing limitation, not a new hole in this diff.

### Feature leak / secrets

- Experimental stages: `unregistered → registered → data_certified → research_qualified → paper_eligible → strategy_eligible` only (0029:120–126). Core kind cannot enter (0029:398–401, 556–559). Retired definitions cannot advance. `record_environment` is hardcoded `'local_research'` on every insert in this range.
- `strategy_eligible` does not flip `indicator_kind` or lifecycle to Core; `core_indicator_definition_for_compute` still excludes it (WU-28 probe). No Live / Trade Eligible / order-admission writes exist in these migrations or `tracer.rs`.
- Holdout results must be exactly the preregistered estimator key set (0031:89–102). Extra keys such as `secret_metric` are refused and do not consume (WU-30 probe). Nested values are uninterpreted; the function does not read optimizer state.
- No new credential-shaped config. Tracer still uses parameterized `query_one`. Probe/script `secret_metric` is a forbidden result key name, not a secret. Compose `POSTGRES_PASSWORD=local-only` is outside this diff.

### Tracer

`run_tracer` now calls `register_experiment_preregistration` instead of a raw `INSERT` (tracer.rs:295–304), matching the 0030 insert guard. `evaluate_toy_spec` reads group sizes from the spec rather than hardcoding 2/2 (issue #97 deferral 1). Snapshot/evaluation inserts remain the pre-existing 0005 contracts.

## Positive Observations

- Exception-safe GUC discipline is copied correctly from 0009 (inner `BEGIN`/`EXCEPTION` disarms, then success-path disarm, then audit append).
- Content-addressed preregistration: identical `(experiment_key, spec_digest)` returns the existing row; a post-hoc spec requires `successor_of = tip`; the original row never mutates; evaluations stay on the original `registration_id`.
- Holdout consume is one row per `holdout_id` even when `gate_passed` is false; invalid result shapes do not consume.
- Budget refusal is an append-only evidence row plus an audit event, not a silent drop.
- `REVOKE ALL ON FUNCTION … FROM PUBLIC` plus table DML revokes match 0025/0028, not a weaker variant.
- Feature boundary is encoded in data: experimental kind + closed stage enum + `local_research` environment, not a comment.

## Residual (not findings)

- Issue #97 / 0009 header: the connecting role owns these tables, so an explicit `set_config('market_mate.*_write','on', true)` still bypasses workflow GUCs. This diff adds guards; it does not remove them.
- Durable app/owner role split remains stage-2 identity work.
- Empty EOD calendar omits the “latest suffix” check in `seal_release_holdout` (0031:305). Documented standing limitation from WU-30; not a regression versus siblings.

## Status

All items: no open security findings.
