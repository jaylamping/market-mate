Verified head 0304e73cd56a49140dc3a9a52342909c389321c7.

Passed: frontend npm run typecheck, npm test (39 tests), npm run build; cargo test --locked; cargo fmt --check; git diff --check; docker compose build frontend.

Production-container browser verification: desktop and 390px toolbar remains at viewport top 0 while scrolling, mobile document width equals viewport width, and Add Assignment dialog appears above the toolbar. No assignment submitted.

Read-only app and acceptance reviews reported no material findings. SQL review not applicable to this frontend-only diff. PR discussion has no external findings.
