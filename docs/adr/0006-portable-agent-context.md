# ADR-0006: Keep shared agent context in the repository

- Status: accepted
- Date: 2026-09-07
- Decision source: Accepted in this task: the user requested implementation of the cross-IDE recommendations on 2026-09-07.
- Implementation: implemented in the linked scope; limitations are stated below.

## Context

IDE-specific memories, locally installed skills, and chat history do not reliably travel with a checkout. Duplicated rule files can conflict.

## Decision

Use root AGENTS.md for shared instructions with native discovery in Cursor and Codex, the two tools in the user-approved scope. Keep architecture, glossary, ADRs, scoped workflow documents, task handoffs, and executable checks separate. Keep personal configuration outside project authority.

## Alternatives and consequences

Copying instructions into each IDE creates drift. Importing the entire glossary into every session adds context cost. Documentation still cannot enforce permissions or make model reasoning identical; runtime controls and reproducible checks provide stronger alignment.

## Verification

[portability guide](../agents/portability.md), [verification guide](../agents/verification.md), [context check](../../scripts/check_agent_context.py), and [doctor](../../scripts/doctor.py). Run `bash scripts/verify.sh context`; use the same bounded fresh-session exercise in each available IDE.

## Reconsider when

An IDE changes instruction discovery or smoke checks reveal missed context. Fix discovery and scoped pointers first; retain one shared policy source.
