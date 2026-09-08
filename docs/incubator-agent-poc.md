# First Incubator agent POC

Research Scout makes one OpenRouter request and records a hypothesis, evidence
gaps, proposed experiment, falsification rule, and limitations. Incubator shows
the assignment, lifecycle, report, provider metadata, and returned usage. This
is research planning, not a backtest, qualification, or authority decision.

## Run locally

Select and save a concrete free OpenRouter model on Agents. The POC reads that
same saved policy volume immediately before recording its dispatch intent.
It does not change the whitelist. The Incubator request modal uses the same bounded runner.

```sh
docker compose build backend agent-driver research-agent incubator-requests frontend
docker compose up -d --no-deps --wait backend agent-driver incubator-requests frontend
docker compose run --rm --no-deps research-agent my-unique-run minimax/minimax-m3:free
```

Visit `http://localhost:3000/incubator`. Workflow changes arrive through SSE without a manual reload.
Repeating a completed or failed run key returns the existing outcome. A key
cannot be reused for a different model. The CLI returns a nonzero exit status
for failed or uncertain runs.

## Boundaries

- The CLI input is `momentum-brief-v1`, original project-authored text stored
  by `incubator_poc_brief()`. It contains no observations or account data. The
  CLI admission function rejects other input IDs. The modal separately admits owner-authored research briefs (see below). This is a narrow POC input
  allowlist; it does **not** certify external processing rights for vendor
  evidence. Connecting entitled research artifacts remains subsequent work.
- Saved model whitelist, a concrete `:free` ID, and freshly retrieved zero
  catalog pricing are all required. Prompt and completion price ceilings of
  zero are sent to OpenRouter. No tools, plugins, provider failover, or repeat dispatch within an assignment is configured. Model selection and separately admitted fallback assignments are described below.
- One request, at most 2,048 output tokens, 120-second HTTP request timeout,
  three-second connect timeout, and 64 KB response limit. Preflight catalog
  access has its existing eight-second timeout. This is not a claim that a
  remote provider stops compute when the local timeout expires.
- The POC permits no spending. Paid models remain selectable in Agents, but
  dispatching them requires a later positive-budget implementation with
  Operating Cost Register reservations and reconciliation. Migration 0039
  models simulated trading costs and must not be used for model charges.
- The command is trusted local orchestration; the model only receives the
  fixed prompt and brief. It has no tools or database session. The runner
  mounts only OpenRouter credentials and its policy, read-only; no broker key.
  The `incubator_runner` database login has no direct privileges on the new
  run/event tables and invokes bounded functions. Existing database PUBLIC
  privileges and host administration remain outside this POC's isolation claim.

## Persistence and failure

Every POC inference request includes the same provider-independent response
contract (`research-json-v1`) in its system message, plus JSON-object response
mode. The contract requires exactly the five typed report fields, bounded
nonempty strings and lists, and plain text list entries without numbering.
The dispatch event stores the contract version and exact request for audit.
The local typed parser is the acceptance boundary: missing, duplicate, extra,
mistyped, fenced, or trailing content fails without automatic repair or retry.
Invalid source text remains inspectable. JSON mode alone does not enforce the
report schema, and models unable to honor the request cannot produce an
accepted report. This standardizes parsing and rendering, not model reasoning
or repeatability of conclusions. The UI owns list numbering, including for
older reports that contain numeric prefixes.

Migration 0053 builds on `engine_admit_research_assignment` and
`record_alpha_shot`. Immutable run configuration is separate from append-only
events; existing immutable assignment rows are never updated to fake progress.
Completed and failed runs each produce an Alpha Shot with result/failure lineage.
Run state comes from ordered events, not the assignment's original scheduled state.

A session advisory lock holds a single runner, while SQL admission prevents a
second CLI assignment while occupied. Manual requests may queue, but preparing and dispatch remain exclusive. Dispatch intent commits **before** the sole generation
POST. A crash after intent is not automatically replayable, even if the request
may never have left the machine. Rerunning that key records `indeterminate` and
never calls the provider again. Uncertain runs hold the lane; clearing that hold
requires a subsequent evidenced reconciliation workflow, not a new run key or
an automatic timeout. There is intentionally no operator override in this POC.

Explicit HTTP rejection and invalid/incomplete report output are preserved as
failures. Transport errors, ambiguous server errors, and interrupted response
reads are indeterminate. Unexpected reported charges also hold the lane.
Generation ID, returned model, serving provider, and usage are stored when
supplied. Missing usage stays null, including for a nominally free model.
The exact request and its SHA-256 are in the dispatch event. Reports are rendered
as plain text, never as commands, HTML, or a source of authority.

## Verify

```sh
bash scripts/incubator_agent_poc_test.sh
cargo test --locked
cargo fmt --all -- --check
cd frontend
npm test
npm run typecheck
npm run build
```

The acceptance script owns only the `market-mate-agent-poc-test` Compose project
and port 15433. It removes that isolated test database on exit and does not stop
or clear the user's stack. Its probe uses nonempty records and both the restricted
runner role and the schema owner to check mutation denial. JSON evidence records
the migration checksum. It does not use API credentials or call a model.

Provider contracts checked for this implementation:
[routing and price caps](https://openrouter.ai/docs/guides/routing/provider-selection),
[usage accounting](https://openrouter.ai/docs/cookbook/administration/usage-accounting).

## Models table

The default sort places saved selections first across both providers, then sorts
alphabetically. Draft checkbox edits do not move rows; saving or refreshing the
policy updates the ordering. Every header can toggle ascending/descending order,
with unavailable values last. A refreshed catalog/policy returns pagination to
the first page. The user-requested **Release Date** heading displays OpenRouter's
`created` catalog-added timestamp in UTC; its tooltip distinguishes that from a
verified original release date. Cursor does not currently supply this date.

## First observed runs

On 2026-09-07 UTC, `poc-minimax-m3-002` completed using
`minimax/minimax-m3:free`, served by GMICloud. The provider reported 385 input
and 681 output tokens, with $0 cost. Reopening that exact key returned an
identical result; the database retained exactly three lifecycle events and one
dispatch intent. See `evidence/incubator-agent-poc/live-run.json`.

The earlier `poc-minimax-m3-001` response failed report validation and remains
visible with its generation ID and reported $0 usage. That initial version did
not preserve its invalid response text; the POC now records bounded response
text, a truncation flag, and a validation diagnostic for future malformed reports.
`poc-whitelist-denial` demonstrates denial before dispatch. No saved policy was
changed by these tests. Neither report is an empirical qualification artifact.

Experiment list numbering is supplied by the UI. Numeric list prefixes produced
by a model are removed only when rendering an ordered list; the recorded report
and raw response are preserved exactly.

## Model preferences and provider order

Agents groups catalog entries by the final model slug, ignoring the prefix
before `/`. Full provider IDs are retained for dispatch. Exact suffixes remain
part of the identity, so free, Pro, preview, and batch entries remain separate;
spelling differences in slugs are not guessed into equivalence.

One atomic `routing.json` in the existing OpenRouter policy volume stores model
approvals and each model's ordered provider routes. Its initial read imports
existing OpenRouter and Cursor whitelists without changing them (OpenRouter
first when both were approved, since the old policies had no cross-provider
order). The first save activates this policy; the legacy per-provider GETs
project its selections and legacy PUTs refuse writes. Saved revisions reject
stale updates, including legacy revisions during the initial import. New
selections must exist in their provider catalog; unavailable saved selections
can still be retained, reordered, or removed. Up to 100 selections per provider
remain enforced. Conflict recovery offers a contextual reload action and preserves drafts when reload fails.

The runner checks the saved first route and records the priority snapshot with
its dispatch intent. A Cursor-first preference currently fails before dispatch
because there is no Cursor execution adapter. It never silently skips the
preferred provider or retries another provider after an uncertain response.
The POC's existing free-model restriction still applies. Automatic provider failover conditions and additional execution adapters remain subsequent work.

Table pricing/context use the saved primary provider's metadata, falling back
to OpenRouter where missing. These are reference values, not a claim about
Cursor billing or effective context guarantees. Catalog parsing preserves nested
pricing tiers; those models are not automatically classified as free.


## Default and fallback model

The selector below the model table stores an optional `default_model` slug in
model preferences. Only approved models can be selected; removing its last
provider clears it. Existing policies default to none. Omitting the model CLI
argument uses this selection and its first provider route.

For a newly started primary run, a confirmed failed outcome can admit exactly
one separate fallback assignment using the saved default. It must differ from
the primary, use an implemented OpenRouter route, and meet the existing free
model budget. Policy changes during the primary prevent automatic fallback.
Completed, dispatched, or indeterminate outcomes never trigger a fallback.
There is no provider retry or fallback chain. Each assignment has its own
one-request limit; a primary plus fallback can therefore make two requests.

Migration 0054 records an immutable, unique parent/child link and checks the
parent is failed, the model differs, and the parent is not itself a fallback.
Repeated admission returns the same child. Run-key replay resumes or returns an
already linked child but never invents a fallback for an old failed primary.
A crash between primary failure and fallback admission sacrifices fallback
liveness rather than guessing whether to start new work. Fallback events retain
the parent run key for display in Incubator provenance. An unsupported or paid
default cannot bypass the POC's execution or zero-spend restrictions.


Model preference controls autosave each change. A write captures the exact new
policy, temporarily disables preference edits while it is in flight, and uses
the returned revision for the next write. Routine autosaves are silent; failed writes retain the draft and expose Retry saving. Conflicts block further
edits until the user explicitly loads the latest policy. Search, filtering, and
table sort remain local view controls. Catalog refresh resets pagination;
autosaving a preference does not reset the current page.

## Per-run research conversation

The Incubator modal has Report and Chat tabs. The Chat view uses the official shadcn Message Scroller and streams decoded text from the model's strict `{"reply":"...","proposal":null}` JSON response (or a full validated plan in `proposal`). The final object is validated before it becomes a completed assistant turn. Streaming text is provisional. Original reports are immutable. A useful refinement can include a complete proposed hypothesis and experiment plan; the owner can inspect it and choose Apply update. This appends a plan revision linked to its originating chat turn. The newest revision becomes the current plan in Report and subsequent model context. The version selector retains access to the original and earlier revisions. A proposal made against an older plan cannot overwrite a newer revision; it must be refreshed in discussion.

The local `incubator-chat` service (internal port 8085) has a separate restricted database identity. The frontend's same-origin POST proxy accepts only localhost origins; the chat service has no published port. It can read run context and append conversation turns/results and owner-applied plan revisions, but cannot admit research assignments, rewrite original reports, use tools, trade, or call other agents. This is the owner-authorized research-discussion exception to the supervisory UI's read-only presentation; order and policy authority remain unchanged.

Every turn binds a client request identity, context revision, owner message, exact outbound request, model, receipt time and Local Research lineage. Dispatch intent and final result are append-only and audited. Conversations include the original assignment/report and all completed preceding turns; failed output remains inspectable but is excluded from model context. The limit is 50 messages and 96 KB outbound context, with an explicit refusal instead of silent history truncation. Each send has one request, 2048 output tokens and a 120-second provider timeout. Four conversations may run concurrently; one pending reply per run is enforced across service instances. Shared approved-model, provider-priority, concrete-free-model and zero-price checks apply on each send. Chat stays on the run's model; automatic fallback and agent-to-agent messaging are not enabled for discussion.

Each open conversation subscribes to the service’s live text channel, including windows that did not initiate the request. Reopening during generation receives the latest partial text and subsequent updates. Decoding accepts either JSON field order. Closing the modal or losing the browser stream does not cancel the server task. Reload reads persisted history and never replays a generation. An uncertain provider outcome or orphaned dispatch pauses that conversation without automatic resend. A reply interrupted by a service restart is shown as outcome unknown after 150 seconds. Full provider responses (including incomplete output) and usage are retained when available. Messages are untrusted Task Memory; they do not become Canonical Evidence or Assignment Handoffs. Future collaboration must use the existing cross-assignment artifact and handoff boundaries rather than treating conversational text as authority.

Verification: `cargo test --workspace --locked`, frontend tests/typecheck, and `scripts/incubator_agent_poc_test.sh` cover streaming framing, JSON validation, retained context, origin protection, idempotency, stale context, independent tasks, restricted role permissions, populated append-only records and audit-chain integrity. Database evidence is `evidence/incubator-agent-poc/chat-acceptance.json`.


## Manual assignments and live workflow

**Add assignment** accepts a title, up to 6,000 UTF-8 bytes of owner-authored research text, and an optional approved free OpenRouter model. Leaving the model blank resolves and pins the configured default at check time. Execution revalidates the whitelist and current pricing. This starts a bounded planning report, not an empirical experiment or a trading action.

Similarity checks cover the full assignment corpus, including queued and finished work and owner-applied plan revisions. Obvious wording overlap is detected locally. Uncertain comparisons use the configured default/fallback model in batches; historical content without an established export permission is compared locally only. At most eight bounded comparison calls are made. Default selection, approval, and pricing are revalidated before every batch. An unavailable model, invalid response, interrupted check, or context limit produces an explicit incomplete-check warning. Neither similarity warnings nor incomplete results create an assignment until the owner chooses **Create assignment anyway**. A clean check queues automatically. Matching records include explanations and links, including records outside the recent-history view.

Checks bind immutable request identities, model choices, and a digest of the compared objectives and plans. Submission verifies that this history has not changed and records the owner's warning decision. Repeating a submission returns the same run. Changing the request requires a fresh check. Comparison dispatches and results remain audited; provider-generated explanations are advisory and never authorize execution.

The internal `incubator-requests` service (8086, no published port) uses the restricted `incubator_runner` identity. Its persistent queue survives browser closure and service restart. A single worker prepares and dispatches each accepted request. An interrupted preparation fails without a primary dispatch; a previously recorded dispatch becomes outcome unknown and holds the lane without automatic retry. A separately admitted fallback preserves the full custom brief. Existing zero-spend and no-tools restrictions remain in force.

The page subscribes to `/api/incubator/assignments/stream`. The server checks persisted workflow state every second and pushes changed snapshots, including a fresh snapshot on reconnect. All active assignments and the latest 100 finished runs remain visible. Card footers show **Assigned → Preparing → Research → Ready**; the upper-right modal timeline shows the full labels and timestamps. Failures and uncertain outcomes are explicit stop states. The report retains the full event history and original provenance.

Run `scripts/incubator_manual_requests_test.sh` for isolated database, restricted-role, HTTP idempotency, startup queue recovery, deterministic semantic checking, between-batch approval revocation, and SSE acceptance. Results are saved in `evidence/incubator-manual-requests/acceptance.json`. The original Incubator acceptance script remains required for CLI, fallback, and conversation regressions.


## Research evaluation and experiment tickets

Incubator separates Research from Experiments. A completed report, including an
owner-applied plan revision, queues one advisory evaluation for that exact
revision. The configured default model performs the evaluation; the original
research model answers clarification questions. These are bounded phases within
the original research assignment, not new supervisory roles or cross-assignment
messages. They confer no independent-evaluation certification. Briefs, pinned
reports and phase answers remain untrusted Task Memory.

The evaluator returns advance, refine, close, or a specific clarification question.
Two agent clarification rounds are allowed. A repeated normalized question or
exhausted allowance exposes Needs your input. One recorded owner answer can resume
evaluation; the overall limit is six model calls per report revision. Further work
requires discussing and applying a revised plan through the existing owner chat.
An answer does not overwrite the report. A later revision supersedes the earlier
evaluation, and an in-flight result for an old revision cannot create a ticket.

An advance result atomically creates one linked experiment planning ticket with
the exact research revision and decision. It is always Awaiting setup: there is
no experiment runner, data entitlement admission, preregistration, empirical result,
or trading authority in this slice. Future experiment agents must use admitted
artifact references and Assignment Handoffs; this phase transcript is not a
cross-assignment communication capability.

The persistent worker in incubator-requests discovers completed reports on startup
and while running. It rechecks the approved free model and zero-price restrictions
before each call and stores the exact request and preflight metadata. A recorded
intent without a result becomes outcome unknown after worker recovery and is never
resent. Failed preparation or provider responses remain visible, with no automatic
retry. Another revised research plan creates a new evaluation; it cannot alter an
existing experiment ticket. Live snapshots update both sections and open details.

Cards show recorded origin: You for manual submissions, Agent for automatic
fallbacks and experiment tickets, and Local runner for earlier CLI runs. Footers
share a fixed-height structure. Failure replaces the affected stage label and bar;
active work uses moving diagonal stripes, disabled under reduced-motion preferences.
Waiting for setup is static and does not imply an experiment is running.

Verify with `scripts/incubator_evaluation_test.sh`, the existing Incubator and
manual-request acceptance scripts, Rust tests, and frontend tests/typecheck/build.
The isolated evaluation suite exercises actual worker orchestration with a
deterministic model adapter, owner-answer HTTP idempotency, SSE experiment delivery,
and recovery without replaying an orphaned model request. It makes no live model
calls. Evidence is stored in `evidence/incubator-evaluation/acceptance.json`.


Experiment details use the research modal layout: a timestamped workflow beside
the title, Report and Chat tabs, and the same strict five-field report parser and
shared list renderer. The Report stays pinned to the evaluated revision, including
its source link. Chat explicitly opens the originating research agent's current
conversation while no experiment agent is assigned. Applying a research revision
can start another research evaluation; it never rewrites the existing experiment.
Legacy numbered list text is preserved in storage, with numbering supplied once
by the shared renderer in both report views.
