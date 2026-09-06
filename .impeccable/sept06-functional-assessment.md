# Frontend assessment — 6 September 2026

Scope: current uncommitted frontend, backed by the running local Research stack. No application source has been changed in this assessment. Prioritize system health and attention, then research and evidence inspection. Design selection is pending in `sept06-directions.json`.

## Verified baseline

- Docker was stopped. Opening Docker restored the existing Compose services; backend, custody, PostgreSQL, and frontend report healthy. No database reset or fixture insertion was performed.
- `GET http://localhost:8080/stage1-surfaces` returns the persisted Stage-1 evidence projection. The dashboard is not entirely mocked, but this local database includes WU fixture records. Those are not operational trading performance.
- `npm run typecheck` passes in `frontend/`.
- Browser inspected at `http://localhost:3000/`. Current visual text is frequently 7–9px, matching source styles. No mobile or production-build claim made yet.

## Functional gaps to address

1. `SupervisoryOverview.tsx` generates nonexistent anchors for Attention, Performance, Capital, Costs, Evidence, Decisions, System Map, and Settings. Route only to implemented views, with truthful labels. Audit Export currently only opens the snapshot summary.
2. Attention links all land on `/surfaces`; cycle links all land on the same snapshot browser. Give each exception its relevant section and each cycle a stable detail target.
3. Null checkpoint positions and pending counts become zero. Keep unavailable values explicit. Unverified custody is missing from attention logic, allowing zero open exceptions despite unverified evidence.
4. Emergency state is hardcoded to `none` without a source field. Remove that unsupported status or explicitly mark it unavailable.
5. Qualification bars take absolute values and impose a minimum length; negatives appear positive and zero appears nonzero. Null S&P comparator becomes zero. Use a signed baseline and retain unavailable/not-applicable distinctions. Comparator denominator must reflect whether the comparator is required.
6. Evidence table labels snapshot completion as checkpoint coverage and attaches global pending events to the first cycle without a per-cycle relationship. Use the actual scope of each source field.
7. `role="img"` on the qualification chart hides descendant numerical content from the accessibility tree; provide a complete accessible description or semantic data representation.
8. `error.tsx` calls `reset`, which does not refetch failed server data. Installed Next.js 16.3 documentation specifies `retry` for refetch and rerender. Add a bounded server fetch timeout and clear recovery copy.
9. Stage-1 costs hide a recorded model when the cost register is missing. Render the two independently.
10. API projection includes latest snapshots and qualification window plan, but the frontend parser drops them. Preserve supported evidence for real inspection; do not invent per-cycle qualification relationships absent from the API.
11. Empty evidence tables lack an explanatory empty state; fixed workspace heights can clip empty/error content and long attention details.

## Implementation and verification boundary

Keep localhost, Local Research, display-only, zero-order-authority guards. Preserve WU-46 section IDs and no authority-bearing controls. A design preview may contain illustrative annotations or generated text: implement only verified domain fields and relationships, with effective independent sample terminology from CONTEXT.md. Do not copy invented per-cycle returns, timestamps, or identity controls from generated comps.

After direction selection: implement the chosen overview and research inspection behavior; exercise populated, empty, pending, unverified, negative-return, optional-comparator, malformed-response, backend-outage, and recovery states. Verify navigation, keyboard use, desktop/mobile containment, typecheck and production build. Preserve existing user edits and keep changes locally reviewable.
