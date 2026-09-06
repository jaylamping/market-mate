# Thermo-nuclear review: WU-30 + WU-31

Range: `1143e26..7d77642` (`main` @ `7d77642`).
Scope: code added/modified in this range for the listed WU-30/WU-31 files, plus traced callees (`core_indicator_session_calendar_as_of`, `experiment_preregistration_spec_node`, `register_experiment_preregistration`, `append_audit_event`).
Specs: `docs/research/stage-1-research-evidence-mvp-work-units.md` WU-30/WU-31; `CONTEXT.md` Release Holdout / Holdout Evaluation / Experiment Family / Experiment Trial; issue #42.

**Verdict: 2 open bugs (both medium), 1 open suggestion.**

## Traced contracts

| Item | Result |
|---|---|
| Holdout ≥60 strictly increasing dates | **OK.** `release_holdout_session_dates_are_valid` (`0031:16-28`): `n < 60`, any NULL, or `dates[i] >= dates[i+1]` → false. Seal raises `at least 60 trading days` (`0031:288-292`). |
| Last trading date ≤ as_of UTC date | **OK.** `as_of_date := (as_of_value AT TIME ZONE 'UTC')::date` then `last_date > as_of_date` raises (`0031:297-302`). Monotonic + this bound implies every session date ≤ as_of UTC date. |
| Future as_of blocked | **OK.** `as_of_value > clock_timestamp()` raises (`0031:282-287`). |
| Digest = `convert_to` UTF8 of the date list; no as_of in digest | **OK.** `release_holdout_seal_digest` (`0031:110-132`) hashes `first_trading_date` / `last_trading_date` / `session_count` / `session_dates` only. `as_of_at` is stored, not digested. CHECK binds `seal_digest` to this function (`0031:151`). |
| One unconsumed seal | **OK.** Under lock `hashtextextended('release-holdout', 31023)` (`0031:324`), same digest returns existing (`0031:326-331`); any other unconsumed row raises (`0031:333-341`). Same-digest reseal of a consumed holdout returns that consumed row and does not unconsume it. |
| Idempotent same digest | **OK.** Probe `idempotent_same_segment`. Unique `(seal_digest)` backstop (`0031:153`). |
| Evaluate consumes including failed gate | **OK.** `gate_passed` is inserted as given (`0031:445-454`). Probe `failed_evaluation_consumes`. |
| Second eval RAISE | **OK.** Existing eval under lock `hashtextextended(holdout_id::text, 31024)` raises `23505` (`0031:431-440`). Unique `holdout_id` on `release_holdout_evaluation` (`0031:160`). |
| Result keys exact preregistered estimators | **OK.** Extra keys and missing names both return false (`0031:89-102`). Raises before consume insert (`0031:423-428`). Probe extra + omit paths do not consume. |
| Empty EOD calendar | **BUG.** See Issue 1. |
| Holm sort, monotone max, `(m-k+1)`, write-back `[0.04,0.01] → [0.04,0.02]` | **OK.** Bubble-sort ascending with index tie-break (`0032:158-168`); `running := greatest(running, least(1, p * (m-i+1)))`; write-back `result[order_idx[i]] := running` (`0032:170-173`). Probe vector asserts `[1]=0.04, [2]=0.02`. Bonferroni `[0.08, 0.02]` also matches. |
| Default Holm for generic string plans | **OK.** `'family-wise error at 5%'` contains neither keyword → `RETURN 'holm'` (`0032:83-92`). |
| Object method `none` rejected | **OK.** Object + `method` not in `{holm, holm-bonferroni, holm_bonferroni, bonferroni}` raises `not an allowed preregistered method` (`0032:66-81`). |
| Bonferroni only if every member preregisters it | **OK.** `record_experiment_trial` / `compute_experiment_family_correction` require identical `experiment_family_correction_method` across members (`0032:482-486`, `0032:615-622`). Probe conflict member blocks. |
| Conflicting methods fail closed | **OK.** Same as above. |
| Exhaustion: INSERT refusal, `RETURN NULL` (no RAISE) | **Not fail-open.** See notes. Trial is not inserted; refusal row + audit event are. `PERFORM` discarding NULL cannot spend budget. |
| Family split via successor changing `experiment_family` | **OK.** Chain walk from the trial's registration to root refuses a changed key (`0032:452-466`). Registration of such a successor is allowed; it cannot record a trial, so it cannot evade the old family's budget. |
| Different `family_trials` among members | **OK.** `IS DISTINCT FROM reserved` raises (`0032:476-480`, `0032:617`). Untested in the probe; SQL is the gate. |
| Holm `m` = members with p-values, not declared family size | **BUG.** See Issue 2. |
| GUC write guards | **OK.** Insert triggers require `market_mate.release_holdout_{seal,evaluation}_write` / `market_mate.experiment_trial{,_refusal}_write` / `market_mate.experiment_family_correction_write` = `on` (`0031:219-237`, `0032:331-364`). Armed with `set_config(..., true)` (transaction-local) and disarmed on `WHEN OTHERS` and the success path. |
| Advisory locks 31023 / 31024 / 32023 | **OK.** Seal serializes on `'release-holdout'`+31023; consume on `holdout_id`+31024; family trial + correction on `family_key`+32023. Distinct from WU-29 `experiment_key`+30023. |
| PUBLIC revoke | **OK.** `REVOKE ALL ON FUNCTION` the four writers; `REVOKE INSERT, UPDATE, DELETE, TRUNCATE` on the five evidence tables (`0031:483-487`, `0032:699-703`). Acceptance scripts assert `has_table_privilege` / `has_function_privilege` for role `public`. |
| Append-only probes `SQLERRM LIKE '%append-only%'` | **WU-31 OK** (three isolated `TRUNCATE`s with table-specific messages). **WU-30 suggestion.** See Issue 3. |
| `jsonb_typeof NOT IN` fail-open | **OK.** This diff does not use `NOT IN` on `jsonb_typeof`. Estimator matching uses `IS DISTINCT FROM 'object'`. Budget unknown types `RETURN NULL` then trial raises. Correction `method` non-string raises. Family key uses `IS DISTINCT FROM 'string'`. |

`jsonb_typeof NOT IN` is the WU-29-class three-valued-logic hole (`NULL NOT IN (...)` is unknown, so the reject branch is skipped). Not present here.

## Issues

### Issue 1 — Severity: medium
- **File**: `db/migrations/0031_release_holdout_custody.sql:305`
- **Description**: `seal_release_holdout` loads `core_indicator_session_calendar_as_of(as_of_value)` (`0031:304`, defined `0028:274-287` as distinct `eod_price_observation.trading_date` with `available_at <= as_of` and `receipt_time <= as_of`). The “most recent N sessions” suffix check runs only when `cardinality(calendar_dates) > 0` (`0031:305-320`). An empty calendar accepts any strictly increasing ≥60-date array.

  That is inconsistent with the non-empty short-calendar path: 1–59 visible sessions raise `requires % sessions visible; the calendar has %` (`0031:306-310`); 0 visible sessions skip the check entirely. WU-30 / fixed decisions require the holdout to be the **most recent ≥60 trading days**. CONTEXT: “chronologically latest evidence segment”. With no visible EOD sessions there is no trading-day suffix to seal.

  When EOD exists later: `0028` is point-in-time. Rows ingested after the seal with `available_at` / `receipt_time` **≤ the original as_of** (licensed-history backfill) change `calendar_as_of(original as_of)` to a real suffix. The already-sealed row is append-only and can still be evaluated, including when it is not that suffix. The same-digest idempotent return is also unreachable after EOD appears, because the suffix check runs **before** the digest lookup (`0031:304` then `0031:322-331`): reseal of the original invented dates then raises instead of returning the existing seal.

  The WU-30 probe never inserts `eod_price_observation`, so this is the only path the ceremony test exercises (`wu30_release_holdout_probe.sql:24-33,83`).
- **Suggestion**: Fail closed when the calendar is empty or shorter than `n`, same as the 1–59 branch. Seed the probe (and any fixture seal) with ≥60 EOD session dates whose `available_at`/`receipt_time` are ≤ `as_of`, and assert a non-suffix window is refused once that calendar exists.
- **Status**: open

### Issue 2 — Severity: medium
- **File**: `db/migrations/0032_evidence_budgets_multiplicity.sql:624`
- **Description**: `compute_experiment_family_correction` walks every preregistration with the family key (`0032:604-608`) but only appends a p-value when that member's **latest** `experiment_trial` has `p_value IS NOT NULL` (`0032:624-633`). Holm/Bonferroni then use `m := cardinality(p_values)` (`0032:146`, `0032:636-647`), and that `n` is stored as `member_count` (`0032:666`).

  WU-31: “Holm correction applies **across family members** by default”. Issue #42: “Holm correction across the **declared finite family**”. Implemented `m` is the count of members that currently expose a non-null p-value, not declared family size and not `family_trials`.

  Untested members that are never rejected do not by themselves inflate FWER at a single final look. Two fail-opens in this implementation do:

  1. `p_value` is optional for every outcome, including `successful` / `failed` / `null` (`0032:218`, `0032:419-422`). A result-bearing trial can consume budget (`0032:384-386` counts every trial row) and then vanish from Holm. Example: members A,B budget 2; A `p=0.04`; B recorded `successful` with `p_value` NULL (or `aborted` after the p-value was observed). Honest Holm on `[0.04, 0.80]` is `[0.08, 0.80]` (neither rejects at 0.05). Omitting B yields Holm `m=1` on `0.04` (rejects).
  2. Only the latest non-null p-value per `registration_id` enters the vector. Earlier result-bearing trials of that member are dropped from multiplicity while still spending budget. Issue #42: retries after outcome exposure consume budget — they remain tests.

  `compute_experiment_family_correction` is also callable after any prefix of the family (append-only snapshots, no “family complete” gate). An interim call uses Holm(`m_observed`) and can reject before remaining members are tested, which is optional stopping without an alpha-spending plan (#42).

  The probe only ever records one non-null p-value per member of a complete two-member family (`wu31_evidence_budgets_probe.sql:134-147`), so it cannot catch this.
- **Suggestion**: Set Holm/Bonferroni `m` to the declared family size (count of preregistrations with that `experiment_family`, or the shared `family_trials` reservation). Treat missing p-values as 1 (non-rejection) so they still inflate the multiplier. Require a non-null `p_value` for result-bearing outcomes (`successful`, `null`, `failed`, `invalid`); keep NULL only for `aborted` / `interrupted` if those must remain non-tests. Include every result-bearing trial, or refuse a second result-bearing trial on the same registration. Store that declared `m` in `member_count`.
- **Status**: open

### Issue 3 — Severity: suggestion
- **File**: `db/fixtures/wu30_release_holdout_probe.sql:256`
- **Description**: Combined `TRUNCATE release_holdout_evaluation, release_holdout_seal` can satisfy `SQLERRM LIKE '%append-only%'` from either table's `BEFORE TRUNCATE` trigger (`0031:207-212`, messages `0031:187` / `0031:200`). PostgreSQL rejects single-table `TRUNCATE` of `release_holdout_seal` before triggers fire because `release_holdout_evaluation.holdout_id` references it. UPDATE and DELETE probes remain isolated. WU-31 split this into three table-specific TRUNCATE blocks; WU-30 did not.
- **Suggestion**: Keep the combined statement (FK). Do not claim `holdout_truncate_blocked` isolates one table's truncate trigger. Optionally assert both table names appear in `SQLERRM`, knowing the second trigger may not run.
- **Status**: open

## Notes (not issues)

- **`RETURN NULL` on exhaustion is fail-closed for spending.** `record_experiment_trial` inserts `experiment_trial_refusal` then `RETURN NULL` (`0032:496-530`) instead of `RAISE` so a caller `EXCEPTION` handler cannot roll back the refusal as a subtransaction abort of the function. `PERFORM record_experiment_trial(...)` discarding NULL does not insert a trial; `experiment_family_consumed_trials` is `count(*)` of `experiment_trial` only. Probe assigns `SELECT * INTO v_trial FROM record_experiment_trial(...)` and requires `trial_id IS NULL` plus `count(experiment_trial)=2` (`wu31_evidence_budgets_probe.sql:150-163`). Not a consume bypass.
- **Successor family split.** `register_experiment_preregistration` does not freeze `experiment_family`. `record_experiment_trial` walks `successor_of` to the root and raises `experiment family cannot change along a registration successor chain` (`0032:452-466`). A renamed successor cannot spend a new family's budget. Cross-`experiment_key` grouping is the explicit `experiment_family` string, not an in-band rename.
- **Mismatched `family_trials`.** Same-budget check is fail-closed at trial and at correction. Probe does not cover it.
- **Object `method: "none"` vs string `"none"`.** Object raises. String `"none"` has no `holm`/`bonferroni` substring and defaults to Holm (`0032:92`) — more conservative than uncorrected, matching “default Holm for generic string plans”.
- **Holdout `gate_passed` and result values are caller-supplied.** WU-30 is custody of one consume + estimator key-set, not the evaluation engine (WU-33+). `{"eis": null}` still matches `?`. Out of scope.
- **Owner-role GUC boundary** is the stage-1 pattern (`0009`). Connecting role `mm` owns the tables; `set_config('market_mate.*_write','on', true)` still bypasses insert guards. Not introduced by this diff; not re-reported.
- **No new env vars, ports, or mandatory setup.** WU-30 pins migration head 31 and WU-31 pins 32, matching the historical per-WU head convention.
- **0028 calendar callee.** Empty array is `coalesce(array_agg(...), '{}')`, never NULL. This diff's skip is `cardinality > 0` (`0031:305`), not a 0028 bug.
