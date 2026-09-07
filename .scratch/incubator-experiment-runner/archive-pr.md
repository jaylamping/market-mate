Research tickets can now be archived from their Report modal and restored from the Archived view. The default Current view hides archived tickets. Archiving changes presentation only: reports, chat, evaluation scheduling, and linked experiments remain intact.

Archive commands are append-only and audited, with request identities and optimistic versions preventing duplicate or delayed requests from undoing a later restore. SSE distributes changes across open pages. Each view retains its own 100 finished/archived-ticket window; restored tickets return to the current window.

Validation: isolated scripts/incubator_research_archive_test.sh (SQL guards, unchanged research/evaluation, HTTP archive/restore, SSE, and delayed replay); cargo test --locked; cargo fmt --check; frontend npm test, npm run typecheck, npm run build; git diff --check.
