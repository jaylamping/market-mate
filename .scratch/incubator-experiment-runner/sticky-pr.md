## Changes
Move View beside Status and group search, filters, refresh, and Add Assignment in a toolbar that stays at the viewport top while scrolling. Controls wrap on narrow screens and remain available in empty or loading states.

## Validation
- Frontend typecheck, 39 tests, and production build passed.
- cargo test --locked, cargo fmt --check, and git diff --check passed.
- Production-container browser checks at desktop and 390px: toolbar sticks at top: 0, no horizontal overflow, and assignment dialog renders above it.
