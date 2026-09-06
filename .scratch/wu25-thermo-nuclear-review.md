# WU-25 thermo-nuclear review

**Round 2: 0 open bugs.**

Branch: `jl/wu-25-principal-pinned-overlay` (HEAD 51dc2e6; round 1 was dacb02c)
Base: `main`
Diff this round: `git diff dacb02c..HEAD`

Round 1 found one bug (renewal with no recorded reason; probe tested empty nomination instead). It is fixed in SQL, not just claimed. Issue 2 (suggestion) was rephrased, not dropped, and is not re-litigated as a bug.

Verified by reading `0027_principal_pinned_overlay.sql` successor_of guards and the probe’s `renewal_reason_required` path. Evidence JSON checksum changed with the migration (`1edc6680…`).

## Highs checked

| # | Item | Result |
|---|---|---|
| 1 | Overlay count >5 (active-as-of, not raw rows); later expiry frees a slot only at the later as_of | **OK.** Unchanged. |
| 2 | Pin consumes `coverage_universe_version.admitted_count` or inserts `system_selected` membership | **OK.** Unchanged. |
| 3 | Pin grants Trade Eligible | **OK.** Unchanged. |
| 4 | Pin blocks safety demotion | **OK.** Unchanged. |
| 5 | Unpinned promotion regression | **OK.** Unchanged. |
| 6 | Duplicate active pin; sixth pin; system-selected pin | **OK.** Unchanged. |
| 7 | Write-GUC / PUBLIC revoke / append-only | **OK.** Unchanged. |
| 8 | Advisory lock on overlay_key (and security key) | **OK.** Unchanged. |
| 9 | Audit event_id uniqueness | **OK.** Unchanged. |
| 10 | Renewal without reason; revival after demoted/expired; expire before review_at | **OK.** Issue 1 fixed (see below). Expire-before-review and same-`pin_id` revival still blocked. |
| 11 | PIT: lifecycle receipt after as_of must not change `current_state_at` | **OK.** Unchanged. |
| 12 | PL/pgSQL variable/column ambiguity | **OK.** Unchanged. |
| 13 | CREATE OR REPLACE dropped SECURITY DEFINER / search_path / privilege revoke | **OK.** Unchanged. |
| 14 | Comments that narrate WHAT | **Suggestion** — Issue 2 still open (rephrased, not removed). |

## Issues

### Issue 1 -- Severity: bug
- **File**: db/migrations/0027_principal_pinned_overlay.sql:749
- **Description**: (Round 1) `pin_principal_overlay` had no reason argument; successor always wrote `'renewed with recorded reason'`; the predecessor `nomination_id` could be reused. Probe `renewal_reason_required` nominated with `''`.
- **Suggestion**: Reject `successor_of` when the nomination is the predecessor’s `nomination_id`; copy the new nomination reason onto the superseded lifecycle row; probe reuse of the original nomination.
- **Status**: fixed

  Round 2 verification: `IF nomination_id_value = predecessor.nomination_id` raises 22023 (`pin renewal requires a new nomination with a recorded reason`). Both ids are `uuid NOT NULL`, so `=` is the distinct-from check. `nominate_principal_candidate` and `principal_nominated_candidate.reason` still require `btrim(reason) <> ''`. Supersede lifecycle reason is `nomination_row.reason`, not a constant (`0027:790-793`). `record_principal_pin_lifecycle` still rejects a blank reason.

  Probe `renewal_reason_required`: `pin_principal_overlay(..., v_noms[3].nomination_id, ..., successor_of => v_pins[3].pin_id)` expects 22023. Happy path then nominates `'renew pin 3 with recorded reason'` and renews with that new `nomination_id`.

### Issue 2 -- Severity: suggestion
- **File**: db/migrations/0027_principal_pinned_overlay.sql:10
- **Description**: (Round 1) `-- A pin cannot grant Trade Eligible: promotion_allowed requires NOT pinned.` narrated the following assignment.
- **Suggestion**: Drop it. The file header already states that a pin cannot grant Trade Eligible.
- **Status**: open

  Round 2: rephrased to `-- Promotion of a pinned subject is refused.` Still narrates the next function. Not a bug.

## Notes (not issues)

- Overlay capacity remains per caller-supplied `overlay_key`.
- `record_principal_pin_lifecycle` still reads current state before the `pin_id` lock (WU-26 pattern).
- Same-`pin_id` revival is blocked; a new pin for a demoted security is not.
- Evaluator `pinned` remains an input fact.
