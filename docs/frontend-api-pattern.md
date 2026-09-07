# Frontend API and styling conventions

Use TanStack Query for browser API state. `frontend/lib/api-queries.ts` owns stable query keys and validated query functions. `QueryProvider` supplies a cache per mounted app; server prefetching creates a new cache per request in `ApiHydration`. Both Paper and System share the Paper query; Overview and evidence details share the research query.

Browser queries call same-origin, read-only Next route handlers. Credentials and internal connector addresses remain server-side. Keep broker adapters and business rules in their backend services: TanStack Query manages frontend request state, not trading authority.

Defaults: 15-second freshness, no focus polling, no automatic retries, no persistent browser cache. Refresh controls specify their exact query keys: connections refreshes Alpaca and OpenRouter status, models refreshes catalog and whitelist, and evidence refreshes research surfaces. Only matching active queries refetch. Failed refreshes hide the affected successful view rather than label old data as connected. Fetches honor cancellation and a timeout. Provider state responses replace prior snapshots. No mutation or trading endpoint is introduced by this migration.

Compose UI from shadcn primitives, Tailwind utilities, and the existing shared light/dark tokens. Small scoped CSS supplements are appropriate where utilities or a primitive do not adequately express a need. Do not add parallel page-level design systems. The pre-existing shell stylesheet is retained; Paper layout now uses utilities.

OpenRouter integration settings use the same query family, with a mutation for an explicit model whitelist. Free and paid models are selectable; generation and Incubator task routing remain unimplemented.
