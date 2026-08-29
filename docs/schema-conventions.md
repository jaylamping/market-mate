# Schema conventions

Binding rules for PostgreSQL tables in Local Research. Later Paper and Live databases reuse the same conventions so records from different environments cannot be commingled.

These conventions do not grant order, credential, or Live authority.

## Record environment

Every durable row that can become evidence is classified by `record_environment`:

| Value | Meaning |
| --- | --- |
| `local_research` | Stage-1 Local Research evidence. Zero order authority. |
| `paper` | Paper Execution Environment records. |
| `live` | Live Execution Environment records. |

Paper and Live values are reserved. Stage 1 inserts `local_research` only. The column exists now so later environments cannot be added as an afterthought or by renaming a table.

`record_environment` is an operational isolation column. It does not replace Execution Environment for order paths, which remain out of scope until those work units.

Store timestamps as `timestamptz` in UTC. Keep source-native time inside source lineage; do not overwrite it with receipt time.

## Evidence tables

A table **carries evidence** when it is registered in `schema_object` with `kind = 'evidence'`. Identity catalogs, migration bookkeeping, and other control tables use `kind = 'control'` and are not evidence.

Every evidence table MUST include these columns, all `NOT NULL`, with no default that would invent provenance:

| Column | Type | Meaning |
| --- | --- | --- |
| `source_lineage` | `jsonb` | Source lineage for the row. MUST be an object with non-empty `source` and `entitlement_version` keys. MAY also carry observation time, receipt-path detail, transformation versions, and other lineage. |
| `receipt_time` | `timestamptz` | When Market Mate received the evidence. Distinct from source-native / availability time. |
| `record_environment` | `record_environment` | Isolation class as above. |

Helper SQL (installed by the baseline migration):

- `source_lineage_is_valid(jsonb)` — true only for an object with non-empty `source` and `entitlement_version`.
- `register_evidence_table(table_name)` — fail-closed if the table is missing the required columns, then registers it as evidence.
- `assert_all_evidence_table_conventions()` — fail-closed if any registered evidence table has drifted.

New evidence tables MUST call `register_evidence_table` in the same migration that creates them, and SHOULD add `CHECK (source_lineage_is_valid(source_lineage))`.

Unregistered public tables MUST NOT store canonical evidence. Vector columns and indexes remain prohibited until a later work unit ungates them.

## Migrations

Versioned SQL files live in `db/migrations/` and are named `{version}_{slug}.sql` with a positive integer version.

Rules:

1. Versions start at `1` and increase by exactly `1` with no gaps.
2. Applying an already-applied set is a no-op.
3. A fresh database that applies the same files reaches the same schema head.
4. A gap, a duplicate version, a checksum change to an applied file, or a missing applied file fails closed — nothing further is applied.
5. Each file runs in a single transaction.

The migrator records applied files in `schema_migration` (`version`, `name`, `checksum`, `applied_at`).
