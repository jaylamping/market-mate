# Portable change review

This is the repository review procedure; no installed skill or particular model is required. Read [the work-unit workflow](wu-loop.md) for when review applies.

1. Fix the review base and head. Inspect the actual diff and relevant callers before classifying findings.
2. Review independent surfaces separately: SQL/state/permissions; backend/frontend/runtime; acceptance/evidence. Use read-only reviewers in parallel when the tool supports them. Otherwise perform sequential passes and disclose the lack of independent reviewers.
3. Trace material failure cases end to end: request identity, uncertain acceptance, runtime roles, policy gates, migration upgrades, existing callers, UI state, and whether tests actually exercise the claimed mechanism.
4. Report only researched actionable findings, with severity, trigger, consequence, and exact file/line. A hypothetical concern is not a finding. Limit review to changed behavior and its effects.
5. After your own analysis, read the PR discussion and evaluate external findings. Resolve findings through fixes, an evidence-backed dismissal, or a clearly scoped follow-up.
6. Verify fixes at the final tree. Report coverage limitations. Bound a review to about 20 minutes; if it reaches that limit, report available findings and unreviewed surfaces rather than implying completion.

A model's confidence does not replace passing checks. A safety property needs a probe of its actual enforcement mechanism; an empty-table no-op or a self-reported success flag is insufficient.
