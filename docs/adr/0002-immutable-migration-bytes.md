# ADR-0002: Preserve applied migration bytes

- Status: accepted
- Date: 2026-09-07
- Decision source: Retrospective: migration checksum enforcement and [PR #151](https://github.com/jaylamping/market-mate/pull/151).
- Implementation: implemented in the linked scope; limitations are stated below.

## Context

Rust binaries embed SQL at build time. The migrator compares each applied version/name/checksum with the bundled files. Even whitespace changes can prevent deployment.

## Decision

Make schema/function changes in a new sequential migration. Preserve exact bytes of applied migrations. Diagnose mismatches by comparing Git, the deployed artifact, and stored checksums; restore verified original bytes instead of rewriting history.

## Alternatives and consequences

Editing an old migration or updating its recorded checksum conceals differences between installed databases. New migrations add history but make upgrades reviewable. Migration 0078 intentionally retains its applied trailing blank line; the scoped .gitattributes rule preserves that exception.

## Verification

[migrator](../../backend/src/migrate.rs), [build embedding](../../backend/build.rs), [.gitattributes](../../.gitattributes). `bash scripts/wu02_migration_test.sh` exercises migration behavior in test projects; inspect its cleanup/ports before running. The doctor compares live checksums read-only.

## Reconsider when

The migration mechanism is deliberately replaced with an audited compatibility plan; formatting preferences are not sufficient grounds.
