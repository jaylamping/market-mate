# WU-28 thermo-nuclear review

**Round 2: 0 open bugs.**

Branch: `jl/wu-28-experimental-observation-states` (HEAD = `main` 1143e26; work is uncommitted)
Base: `main` (1143e26)
Diff this round: working tree vs round 1. Evidence checksum `243af7d7…` matches the working-tree `0029_experimental_observation_states.sql` (changed from round 1 `8832d141…` with the completeness rewrite). The index copy is still the pre-round-1 staged file (`NOT IN`, `now()`, `receipt_time DESC`); do not commit that.

Round 1 found 1 bug (absent-key completeness fail-open) and three suggestions (reverse probe isolation, unused `predecessor_text`, circular-FK TRUNCATE). Issues 1–3 are fixed in SQL/probe, not just claimed. Issue 4 remains a standing limitation, not a bug, and is not re-opened.

Verified by reading `experimental_preregistration_spec_is_complete`, the omit-key FOREACH, the post-spine reverse probe, the dropped `predecessor_text`, combined TRUNCATE, the acceptance-script gate list, and evidence JSON. Confirmed on the WU-28 database: omitting `horizon`/`universe`/`stopping_rule`/`promotion_gate`/`testing_budget` now returns false (complete spec still true). Bring-up log ends `WU-28 COMPLETE`.

## Highs checked

| # | Item | Result |
|---|---|---|
| 1 | Point-in-time / `now()` collisions | **OK.** Unchanged. WT still uses `clock_timestamp()` and chain-tip. |
| 2 | Look-ahead / future as_of | **OK.** Unchanged. |
| 3 | Experimental accepted as Core / `strategy_eligible` flipping kind | **OK.** Unchanged. Reverse now runs after `strategy_eligible`; Core exclusion still probed there. |
| 4 | Promotion without complete #42 preregistration / incomplete lineage | **OK.** Issue 1 fixed (see below). Lineage missing-key / digest / JSON-null predecessor unchanged. |
| 5 | Stage skip / reverse / Core transition | **OK.** Skip unchanged. Reverse is now `strategy_eligible -> paper_eligible` requiring the illegal-transition message (Issue 2 fixed). |
| 6 | Unique-constraint / audit `event_id` collisions | **OK.** Unchanged. |
| 7 | Direct INSERT bypassing workflow GUC | **OK.** Unchanged. |
| 8 | Advisory lock not on the actual unique key | **OK.** Unchanged. |
| 9 | Digest timezone / WU-06 domain | **OK.** Unchanged. |
| 10 | PL/pgSQL RETURNS TABLE / variable vs column | **OK.** Unchanged. New probe vars are `v_omit` / `v_omit_spec` / `v_omit_prereg`. |
| 11 | CREATE OR REPLACE dropping SECURITY DEFINER / `search_path` / revoke | **OK.** Unchanged. |
| 12 | Comments that narrate WHAT | **OK.** Issue 3’s unused variable is gone. File header only. |
| 13 | Public EXECUTE left on write functions | **OK.** Unchanged. |
| 14 | Idempotent paths hiding illegal transitions | **OK.** Unchanged. |
| 15 | Chain-tip vs timestamp “latest” | **OK.** Unchanged in WT. |
| 16 | Different preregistration than the one bound at register | **OK.** Unchanged. |
| 17 | Probe `WHEN OTHERS` swallowing `probe corrupted` | **OK.** Omit-key loop and reverse both re-raise unless the isolated message matches. |
| 18 | TRUNCATE of one table masked by FK | **OK.** Combined TRUNCATE of both tables restored. |
| 19 | One preregistration binding two definition versions | **OK.** Unchanged. |
| 20 | Retired experimental entering stages | **OK.** Unchanged. Sequential retire-then-register still probed. |
| 21 | Core entering experimental stages | **OK.** Unchanged. |
| 22 | Lineage predecessor JSON null vs absent vs stale | **OK.** Unchanged. |
| 23 | View `current_experimental_indicator_stage` picking a non-tip | **OK.** Unchanged in WT. |
| 24 | Circular FK making TRUNCATE probes pass for the wrong reason | **Suggestion** — Issue 4 limitation stands; not a bug. |

## Issues

### Issue 1 -- Severity: bug
- **File**: db/migrations/0029_experimental_observation_states.sql:33
- **Description**: (Round 1) `jsonb_typeof(...) NOT IN (...)` treated a missing key as SQL NULL, so `IF NULL THEN` skipped and a spec without `horizon`/`universe`/`stopping_rule`/`promotion_gate`/`testing_budget` was complete. Probe only dropped `hypothesis`.
- **Suggestion**: Rewrite with `IS DISTINCT FROM` per allowed type; probe each omitted key.
- **Status**: fixed

  Round 2 verification: each typed field uses `jsonb_typeof(x) IS DISTINCT FROM 'string' AND ... IS DISTINCT FROM '<other>'` then separate empty-string / empty-object checks (`0029:33-89`). `NULL IS DISTINCT FROM 'string'` is true, so absence returns false. JSON `null`, empty string, and empty object still fail. Live check: `minus_horizon`/`minus_universe`/`minus_stopping_rule`/`minus_promotion_gate`/`minus_testing_budget` are false; complete spec is true.

  Probe FOREACH (`wu28_experimental_observation_states_probe.sql:236-271`) inserts a fresh preregistration for each omitted key and requires `SQLERRM LIKE '%spec is incomplete for experimental indicator promotion%'`. Accepted missing keys would raise `probe corrupted: spec missing % was accepted`, which does not match and re-raises. Evidence `gates.incomplete_horizon_blocked` (and universe/stopping_rule/promotion_gate/testing_budget) are true; the acceptance loop and `jq -e` require them.

### Issue 2 -- Severity: suggestion
- **File**: db/fixtures/wu28_experimental_observation_states_probe.sql:450
- **Description**: (Round 1) Reverse probed `to_stage='unregistered'` at `registered` and accepted `%stage arguments are invalid%`.
- **Suggestion**: After the full spine, request `paper_eligible` from `strategy_eligible` and require `transition % -> % is illegal`.
- **Status**: fixed

  Round 2 verification: the `unregistered` reverse block is gone. After the happy-path advance to `strategy_eligible` (`probe.sql:587-599`), `advance_experimental_indicator_stage(..., 'paper_eligible', ...)` requires `SQLERRM LIKE '%transition strategy_eligible -> paper_eligible is illegal%'` (`probe.sql:631-650`). `'paper_eligible'` is a legal destination argument, so this cannot pass via the invalid-args path. Unique `(definition_version_id, to_stage)` would also block re-occupying `paper_eligible`, but a unique-violation message would not match and would re-raise. Skip `registered -> paper_eligible` is still a separate probe.

### Issue 3 -- Severity: suggestion
- **File**: db/migrations/0029_experimental_observation_states.sql:317
- **Description**: (Round 1) `experimental_indicator_lineage_manifest_is_valid` declared unused `predecessor_text text`.
- **Suggestion**: Drop the variable.
- **Status**: fixed

  Round 2 verification: the function body starts at `BEGIN` with no `DECLARE` (`0029:312-364`). `predecessor_text` is absent from the migration.

### Issue 4 -- Severity: suggestion
- **File**: db/fixtures/wu28_experimental_observation_states_probe.sql:706
- **Description**: (Round 1) Combined `TRUNCATE experimental_indicator_stage, experimental_indicator_lineage` can pass from either table’s `BEFORE TRUNCATE` trigger because the FKs are circular. UPDATE-on-stage and DELETE-on-lineage still isolate those operations.
- **Suggestion**: Keep truncating both tables. PostgreSQL rejects single-table `TRUNCATE` with `cannot truncate a table referenced in a foreign key constraint` *before* triggers fire, so split TRUNCATE cannot isolate the mechanism. Combined TRUNCATE plus `SQLERRM LIKE '%append-only%'` is the available fail-closed check.
- **Status**: open

  Round 2 verification: split TRUNCATE was attempted and restored to the combined statement (`probe.sql:705-712`). Not re-opened as a bug. Limitation stands for this WU.

## Notes (not issues)

- Index vs working tree is unchanged from round 1 in kind: land the WT file (chain-tip, `clock_timestamp()`, `IS DISTINCT FROM` completeness). The staged blob is still the fail-open `NOT IN` version.
- Completeness remains a WU-28 promotion subset, not the full #42 schema. Issue 1 was only that listed fields could be omitted; that hole is closed.
- Round-1 notes on retire-then-advance, core-then-advance, non-null stale predecessor, `LIMIT 1` on tips, and lifecycle check-then-lock are unchanged and not re-litigated.
- No new env vars, ports, or mandatory setup. Head is still migration 29. No new bugs from the FOREACH omit loop or the moved reverse probe.
