Research cards now have an archive icon immediately left of the open arrow. Archived cards show a restore icon in the same position. The icon is a separate button from the card's open trigger, uses the existing archive mutation, and includes a tooltip, accessible label, pending indicator, and visible errors.

Validated with the existing archive acceptance script, cargo test --locked, cargo fmt --check, frontend npm test (39 passed), typecheck, production build, and git diff --check. No SQL/backend changes.
