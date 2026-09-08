<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

## UI state and data ownership

- Use TanStack Query for API reads, mutations, cancellation, freshness, and cache invalidation. Do not mirror server data into Zustand.
- Use the provider-scoped Zustand workspace store for shared persona selection, overlays, and search. Keep form drafts local so background refetches cannot overwrite edits.
- Use TanStack Table for model-table behavior. This repository uses v9 (`useTable`, explicit features, `helper.columns`); inspect installed types before copying v8 examples.
- Saves use revision checks. Preserve drafts on errors; refresh cached saved configuration so the user can reconcile. Catalog discovery never enables a provider or model.
- Keep account-wide provider information separate from model-specific offerings. Missing usage remains unknown and local counters must be labeled.
