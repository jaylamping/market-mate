# Market Mate agent instructions

## Start here

1. Read [the architecture map](docs/architecture.md) before exploring an unfamiliar subsystem.
2. Run `python3 scripts/doctor.py --runtime` for local repository, tool, migration, and container state. This is read-only; an unavailable service is not permission to start it.
3. Read the task's issue/PR or [handoff](docs/handoffs/README.md). Verify its branch, commit, and remaining work against Git and GitHub before continuing.
4. Use the subsystem links below; read relevant sections rather than loading all research documents.

## Boundaries that apply to every task

- The deployed application is Local Research. Incubator output is research planning or exploratory diagnostics, not trading authority or proof of economic edge.
- Preserve the separation of Incubator, Engine, and Sentinel in [CONTEXT.md](CONTEXT.md). The glossary includes future design; check implementation before claiming a capability exists.
- Use persisted model approvals and spending policies. Catalog availability, an IDE subscription, or a prior successful call is not new provider/model authorization. Preserve existing limits when recovering work.
- Preserve uncertain provider outcomes as `indeterminate`. Reconcile them before another dispatch; a timeout does not prove rejection.
- Link failures and recovery attempts to their originating requests. Retain prior outcomes; new retries have new identities and explicit lineage.
- Applied migration bytes are immutable, including whitespace. Add a new migration for changes. Never rewrite migration checksums to make a deployment pass.
- Keep credentials out of Git, prompts, logs, handoffs, and screenshots. Use the existing credential setup and service boundaries.
- Read-only investigation, reversible fixes, and tests within the requested scope may proceed. Changing model/spending authority, enabling Paper/Live execution, destructive data changes, or sending external messages requires the applicable explicit user authorization. Existing authorization persists within its stated scope; verify it rather than repeatedly asking.
- Current explicit user instructions govern task scope and take precedence over repository defaults. Surface conflicts affecting authority or data integrity; do not silently resolve them by weakening a control.

## Where to go next

| Work | Read |
| --- | --- |
| Rust, SQL, services, runtime roles | [Architecture](docs/architecture.md), relevant source, and [ADRs](docs/adr/README.md) |
| Frontend behavior or layout | [Frontend instructions](frontend/AGENTS.md), [DESIGN.md](DESIGN.md), shared components and existing tests |
| Domain vocabulary or policy decisions | Relevant terms in [CONTEXT.md](CONTEXT.md), [domain guidance](docs/agents/domain.md), linked issue decisions |
| Build, test, migration, deployment | [Verification guide](docs/agents/verification.md) |
| Implementation through PR merge | [Work-unit workflow](docs/agents/wu-loop.md) |
| GitHub issues and dependencies | [Issue tracker](docs/agents/issue-tracker.md), [triage labels](docs/agents/triage-labels.md) |
| Switching IDEs, models, or machines | [Agent portability](docs/agents/portability.md), [handoff template](docs/handoffs/TEMPLATE.md) |

## Working agreement

- Scope changes to the requested task; preserve other work in the checkout. Use a separate worktree for concurrent writers, with one branch per task.
- Prefer existing components, SQL functions, and acceptance scripts. Consult package scripts and the lockfiles for actual commands and versions.
- Run `bash scripts/verify.sh` for the standard checks, plus the relevant acceptance suites from the verification guide. Report skipped or unavailable checks accurately.
- Verify UI interactions in a browser when changing them. A successful build alone does not establish correct behavior.
- Inspect the exact staged diff before commit. Report the tested commit/tree, runtime evidence, remaining limitations, and issue/PR links.
- Keep shared decisions in this repository or linked GitHub issues. Personal IDE memories and optional plugins are conveniences, not project authority.
- When a decision changes, update its ADR and affected instructions in the same PR. When handing off unfinished work, write a task-specific handoff; completed history belongs in its PR.
