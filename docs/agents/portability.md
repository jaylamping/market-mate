# Switching agents and IDEs

## Shared context for Cursor and Codex

Open the repository root in both tools. Root [AGENTS.md](../../AGENTS.md) is canonical; both tools use it directly. Preserve the scoped [frontend instructions](../../frontend/AGENTS.md) for frontend work. Do not maintain duplicate project policy in `.cursor/rules` or personal Codex memory.

Cursor's root and nested AGENTS.md support was checked on 2026-09-07 against [Cursor rules](https://prod.cursor.com/docs/rules). Confirm loaded instructions in a fresh session after tool upgrades. This setup targets Cursor and Codex; other IDE integrations are outside the current scope.

Keep personal response style, optional skills, and machine-specific paths in user-level configuration. Audit personal/global rules for conflicts with repository instructions when switching tools. Do not copy credentials or full configuration directories across tools. Match permitted capabilities (Git/GitHub, shell, browser verification) where practical; record missing capabilities. An IDE subscription does not authorize Market Mate to use its provider.

## Incoming session

1. Read AGENTS.md and the architecture map. Run the doctor. Refresh relevant Git/GitHub state before selecting work; fetching updates refs and does not deploy anything.
2. Read the relevant issue/PR and task handoff, if present. Check whether it was already merged or superseded.
3. Identify the exact module, applicable ADRs, existing verification, and authority constraints. Treat runtime observations in a handoff as stale until refreshed.
4. Continue the next concrete step. Use a separate worktree if another agent is writing. Do not share a mutable handoff file across tasks.

## Fresh-session alignment exercise

Run the identical prompt below in a new session in each tool, using its existing configured model. Use plan/read-only mode; do not enable permission bypasses. This exercise requires no provider configuration changes or Market Mate model calls. IDE inference itself can use the tool's normal account allowance.

> Read the repository's agent instructions and relevant context. Do not edit files, invoke other agents, start/restart services, change settings, or dispatch Market Mate requests. Explain where you would change campaign retry behavior. Report: (1) instruction files you loaded, (2) current implementation versus planned trading capabilities, (3) five relevant invariants including migration bytes, uncertain acceptance, request lineage, and model/spending authorization, (4) exact source paths and verification commands, (5) what live state you must refresh before acting. Cite repository paths. Keep the answer under 500 words.

Score each response against the same checklist: shared/nested instruction discovery; accurate Local Research boundary; all requested invariants; real source/check paths; fresh-state awareness; no mutations. Record tool version, reported model when available, commit/tree, timestamp, outcomes and limitations in a task-specific evidence JSON. Differences in prose are expected. Missing constraints or invented commands identify a discovery/context gap to fix. A single exercise is a smoke check, not proof of equal future behavior.

The initial [Cursor/Codex CLI smoke record](../../evidence/agent-portability/alignment.json) records the tested context hashes and limitations. Both recovered the key retry constraints. Codex could not inspect Docker or GitHub from its read-only sandbox and reported that uncertainty. Frontend-specific discovery and full IDE GUI behavior were not tested.

## Outgoing session and maintenance

Use [the handoff template](../handoffs/TEMPLATE.md) for unfinished work. Update relevant ADRs and architecture links alongside implementation changes. Keep decisions, live state, and glossary entries separate. Run `bash scripts/verify.sh context` after changing this layer. Repeat the fresh-session exercise when instruction discovery or shared workflow changes materially.
