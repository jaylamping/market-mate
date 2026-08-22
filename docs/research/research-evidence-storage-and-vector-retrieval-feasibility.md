# Research evidence storage and vector-retrieval architecture feasibility

Research date: 2026-08-21  
Scope: Market Mate's single-Principal, cloud-hosted Paper/Live trading platform, with a bounded Coverage Universe that targets 40 system-selected securities and normally caps at 50. This is an architecture decision, not an investment recommendation.

## Decision summary

Use a **three-tier evidence architecture**:

1. **PostgreSQL is the authoritative transactional store.** It owns exact relational facts, append-only corrections, versioned definitions and policies, point-in-time metadata, ledgers, Decision Records, Research Snapshots, experiment lineage, and the catalog of every external artifact. It is the only store that may satisfy a live authority, ledger, reconciliation, or promotion gate.
2. **Cloud object storage is the canonical payload/archive store.** It holds large raw or normalized files, licensed payloads when the Source Registry permits retention, immutable exports, backup material, and replay fixtures. Objects are addressed by content hash and linked from PostgreSQL. Versioning, checksums, encryption, lifecycle, and optional WORM retention are applied per source contract; a source deletion duty always overrides a generic archive preference.
3. **PostgreSQL with `pgvector` is the first semantic-retrieval implementation.** It stores only derived embeddings and retrieval metadata linked to canonical evidence IDs. Start with exact nearest-neighbor search, then benchmark HNSW or IVFFlat. A separately managed vector service is a later optimization, not a second system of record.

Do not start with a separate vector database or a lakehouse. The bounded universe, daily cadence, single Principal, low expected QPS, and safety-critical provenance requirements favor fewer authoritative stores and one rebuildable retrieval index. A dedicated vector service becomes viable only after the measurable thresholds in this report are met and the service can be rebuilt from PostgreSQL/object storage without changing a Decision-Time View or granting any trading authority.

The vector layer is **derived, disposable, and non-authoritative**. Similarity scores, nearest-neighbor order, embeddings, generated summaries, and retrieval failures must never directly authorize an order, change a Risk Decision, mutate a Strategy Version, or silently replace an Indicator Observation or Research Snapshot.

## Existing constraints this decision must preserve

The recommendation is aligned with the existing [Market Mate glossary](../../CONTEXT.md), [market-data provenance decision](https://github.com/jaylamping/market-mate/issues/9), [source authorization policy](./sentiment-source-policy-and-authorized-ingestion.md), and [ledger/reconciliation decision](https://github.com/jaylamping/market-mate/issues/16):

- Every observation has source lineage, instrument identity, event/effective/availability/receipt timing, freshness, correction state, and a stable canonical ID.
- `Research Snapshot`, `Indicator Observation`, `Sentiment Assessment`, `Sentiment Contribution Ledger`, `Experiment Trial`, `Decision Record`, `Risk Decision`, `Venue Event`, `Execution Result`, `Capital Ledger`, and `Paper Ledger` remain versioned and independently auditable.
- Paper and Live records are never commingled. A common cloud host does not create a common authority boundary.
- Source Registry permissions cover access, collection, raw retention, transformation, derived retention, display, deletion, rate, cost, and account scope. Public availability is not a license.
- A corrected or deleted source creates a `Corrected Research View` or invalidation path without rewriting the historical `Decision-Time View`.
- Operating Costs are separate from the $1,000 trading allocation and must be included in fully loaded cost reporting.
- The Safety Kernel, Options Lifecycle Engine, compliance controls, ledgers, and authority grants are deterministic and fail closed. Retrieval is never on the order-authority path.

## What belongs where

| Data class | Canonical owner | Required properties | Vector/index treatment |
|---|---|---|---|
| Ledger Events, Ledger Postings, Cash Movements, Position Lots, tax/economic basis, reconciliations | PostgreSQL | Balanced, exact, append-only corrections, relational constraints, environment binding, deterministic replay | Never vector-only; vectorize only an explicitly approved explanatory copy, if at all |
| Venue Events, Order Plans, Venue Orders, Execution Results, capability/certification records | PostgreSQL plus raw response object | Exact payload/hash, venue and receipt timing, idempotency, correction lineage, Paper/Live binding | Derived semantic index may point to IDs; never supplies current custody or order state |
| Source Registry, Data Contracts, entitlements, retention/deletion decisions | PostgreSQL | Versioned authority, scope, expiry, provider terms, deletion obligations | Filter metadata only; source permissions are enforced before retrieval |
| Indicator Definitions and Observations, Sentiment Assessments and Contribution Ledgers | PostgreSQL | Definition/model/source versions, units, timing, freshness, uncertainty, evidence state, correction state | Store embeddings of authorized explanatory text/events only; numerical observations remain relational |
| Research Snapshots, Experiment Registrations/Trials/Lineage, Model/Strategy Versions, Promotion Bundles, Decision Records | PostgreSQL plus immutable export/object | Exact versions, hashes, holdout boundaries, evidence links, actor/time, append-only state transitions | Retrieval can find related evidence, but the canonical record is fetched by ID and rechecked |
| Large filings, authorized news bodies, bulk market files, option-chain archives, replay fixtures, signed exports, backups | Object storage when the Source Registry permits it | Content hash, receipt time, source/accession, license scope, retention, encryption, checksums, version/tombstone | Embed only permitted derived text/chunks; never assume object existence means current validity |
| Embeddings, chunk text where authorized, ANN index metadata, similarity scores, retrieval traces | `pgvector` first; later optional vector service | Model/version, dimensions, preprocessing/chunking version, canonical evidence ID, content hash, environment, creation time, index version, status | Rebuildable derived index; query results must resolve to canonical records and be filtered by as-of time and entitlement |

The canonical rule is: **PostgreSQL decides what a record means; object storage preserves authorized bytes; vector retrieval helps locate records.**

## Candidate comparison

| Option | Strengths | Safety/data-integrity limits | Operational and cost posture | Decision |
|---|---|---|---|---|
| Plain PostgreSQL, no vector index | ACID transactions, constraints, joins, MVCC, row-level security, SQL time filters, full-text/JSONB indexes, one replayable authority; simplest Paper/Live isolation | Semantic “find similar evidence” is weaker; full-text search is lexical unless an embedding extension is added; very large payloads inflate backups | Lowest operational burden. A representative RDS `db.t4g.micro` example is $0.019/hour ($13.87 per 730-hour month) before storage, backups, I/O, transfer, and monitoring. [AWS RDS getting started](https://docs.aws.amazon.com/AmazonRDS/latest/gettingstartedguide/rds-gsg.pdf), [RDS pricing components](https://aws.amazon.com/rds/postgresql/pricing/) | Required baseline and system of record. Use first for exact filters, joins, and audit views. |
| PostgreSQL + `pgvector` | Keeps vectors beside lineage and relational filters; ACID/PITR/JOINs remain available; exact search is perfect-recall; HNSW/IVFFlat are available when needed; one backup/recovery plane | ANN trades recall for speed; approximate filtering can return too few rows; HNSW uses more memory and builds more slowly; vector index maintenance competes with canonical workloads; extension/version portability must be tested | No separate license or service floor. Incremental cost is mainly memory/compute, backup, and operator testing. It is the lowest-cost way to add semantic retrieval while preserving authority. [pgvector README](https://github.com/pgvector/pgvector) | Recommended first vector implementation, gated by benchmark and feature flag. |
| Separate managed vector DB (Pinecone representative) | Managed ANN scaling, namespaces, hosted embeddings/reranking options, backups on production plans, lower application-side index maintenance | Documented eventual consistency means writes/deletes may not be immediately visible; asynchronous index cannot atomically commit with PostgreSQL; source deletion and backup-retention semantics require a second compliance path; vendor/API/region lock-in | Pinecone Builder is $20/month; Standard has a $50/month minimum and includes backup/restore, RBAC/SSO, and import from object storage; Enterprise has a $500/month minimum. [Pinecone pricing](https://www.pinecone.io/pricing/), [Pinecone data freshness](https://docs.pinecone.io/guides/manage-data/delete-data), [Pinecone security/backups](https://docs.pinecone.io/guides/production/security-overview) | Defer until pgvector fails measured SLOs. If selected later, retain canonical data in PostgreSQL/object storage and use a separate index/namespace per environment. |
| Object storage plus lakehouse/Apache Iceberg | Cheap durable bulk retention, independent replay/export, table snapshots/time travel, schema/partition evolution, analytics-friendly bulk scans; can support long histories without enlarging the transactional database | Object store is not a low-latency transactional ledger; catalog/compaction/query-engine permissions and maintenance add complexity; raw licensed content may require deletion that conflicts with WORM or long-lived snapshots; not a direct semantic index | AWS S3 Standard is published at $0.023/GB-month for the first 50 TB; 100 GB is about $2.30/month and 1 TB about $23.55/month before requests/egress/replication. Apache Iceberg/S3 Tables add catalog, maintenance, compaction, and query-engine costs. [AWS S3 pricing example](https://docs.aws.amazon.com/solutions/latest/live-streaming-on-aws-with-amazon-s3/cost-example-1.html), [S3 Tables/Iceberg](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables.html), [Apache Iceberg snapshots](https://iceberg.apache.org/docs/latest/branching/) | Adopt as the payload/archive tier from the first evidence MVP; defer full lakehouse/table-bucket machinery until volume or analytical concurrency warrants it. |
| No-vector baseline (PostgreSQL + object storage only) | Lowest complexity and lock-in; proves provenance, point-in-time replay, licensing, correction, dashboard, and experiment contracts before semantic retrieval | No semantic similarity; agent/operator search must use exact fields, full-text, tags, and curated links; may leave useful research retrieval unexplored | Lowest cost and easiest failure model; storage bytes are inexpensive compared with market-data entitlements, model inference, and operating labor | Required baseline for validation. It must remain available as a fallback even after a vector index is added. |

### Additional managed options considered

Amazon OpenSearch Serverless is a credible AWS-native vector/search option but not a sensible starting cost for this single-Principal workload. Its pricing page documents $0.24 per OCU-hour in examples; classic collections have a minimum of 2 OCUs (one indexing and one search) for the first collection, or a dev/test mode with 0.5 OCU for each. That is approximately $350.40/month for 2 OCUs or $175.20/month for the 1-OCU dev/test floor at 730 hours, before storage and other services. [OpenSearch pricing](https://aws.amazon.com/opensearch-service/pricing/), [OpenSearch capacity limits](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/serverless-scaling.html)

Amazon S3 Vectors is a new object-integrated vector option worth revisiting during the dedicated-service gate. Its published example prices include $0.06/GB-month storage, $0.20/GB uploaded, and $2.50 per million query requests, plus data-processed and data-returned charges. It is attractive for very large, infrequently updated vector archives, but its AWS-specific semantics and the need to keep relational metadata elsewhere mean it does not displace PostgreSQL. [S3 Vectors pricing](https://aws.amazon.com/s3/pricing/)

Google Cloud Storage provides a portability reference: Standard storage in Iowa is listed at $0.000027397/GiB-hour, approximately $0.02/GiB-month, with separate operation, retrieval, and transfer charges. This is evidence that the archive tier is portable across major clouds; it is not a provider selection. [Google Cloud Storage pricing](https://cloud.google.com/storage/pricing)

## Recommended logical architecture

### PostgreSQL authoritative schema

The architecture decision should reserve PostgreSQL schemas or databases for:

- `control`: Source Registry, Data Contract, retention/deletion decisions, cloud/provider configuration references, and immutable policy versions.
- `research`: instrument identity, event calendar, raw-source manifests, normalized observations, Research Snapshots, Indicator Definitions/Observations, Sentiment Assessments, Sentiment Contribution Ledger, and correction/invalidation lineage.
- `experiments`: Experiment Registration, Experiment Family, Testing Budget, Experiment Trial, holdouts, evaluation paths, negative controls, and Strategy/Model Version references.
- `decision`: Decision Records, Expected P&L distributions, forecasts, proposals, promotion bundles, lifecycle transitions, authority grants, and retrieval traces used in an explanation.
- `paper` and `live`: environment-specific ledgers, Venue Events, execution results, reconciliation state, positions, lots, and exposure. These require separate roles and environment checks; a shared physical cluster is not sufficient evidence by itself.
- `vector_catalog`: one row per derived chunk/embedding/index membership, containing canonical evidence ID, object URI if applicable, content hash, source/entitlement reference, execution environment, as-of bounds, embedding Model Version, preprocessing/chunking version, dimension/metric, index version, status (`current`, `stale`, `invalidated`, `purged`, `rebuild_pending`), and last verification time.

Use relational constraints, `NUMERIC` precision for monetary values, unique idempotency keys, append-only correction tables, and application roles that cannot update historical facts. PostgreSQL MVCC gives each statement a consistent snapshot, and serializable isolation is available for stronger conflict control. [PostgreSQL MVCC](https://www.postgresql.org/docs/current/mvcc-intro.html)

Partition only measured large time-series tables by bounded time or environment. PostgreSQL notes that partitioning can improve access to hot partitions and make bulk loads/deletes faster, but also says the benefit normally appears when a table would otherwise be very large. [PostgreSQL partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html)

### Object storage layout

Use provider-neutral object keys with a cloud adapter, for example:

```text
raw/{source_id}/{instrument_or_scope}/{available_date}/{content_hash}
normalized/{contract_version}/{scope}/{as_of_date}/{content_hash}
replay/{dataset_version}/{environment}/{window}/{content_hash}
exports/{record_type}/{environment}/{decision_or_snapshot_id}/{content_hash}
backups/{system}/{environment}/{backup_epoch}/{content_hash}
```

Every object manifest belongs in PostgreSQL and includes source, account, entitlement, receipt time, effective/available time, content hash, media/schema version, region, encryption key reference, retention deadline, legal-hold status, deletion/tombstone state, and the Decision-Time Views that consumed it. Object keys are not authority; the manifest and the source contract are.

For immutable audit exports or signed backup manifests, S3 Versioning/Object Lock can provide WORM protection and legal holds. AWS documents that Compliance mode prevents deletion even by the account root during retention, and that Object Lock requires Versioning. Use this only for data the relevant source contract permits keeping; a provider deletion obligation must not be blocked by a blanket WORM rule. [S3 Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html)

Encrypt object data at rest and in transit. S3 automatically encrypts new uploads with SSE-S3; customer-managed KMS keys are available when independent key custody and rotation are required. [S3 encryption](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingServerSideEncryption.html), [S3 KMS encryption](https://docs.aws.amazon.com/AmazonS3/latest/userguide/specifying-kms-encryption.html)

### Derived vector index

The first implementation should use an explicit `pgvector` table, not vectors scattered through unrelated evidence rows:

```text
embedding_id
canonical_evidence_id
execution_environment
source_registry_version
content_hash
chunk_id / chunk_offsets
embedding_model_version
embedding_preprocessing_version
embedding_dimension / distance_metric
embedding_created_at
evidence_available_at / evidence_effective_at
index_build_version
status
```

Store the embedding and a small, authorized retrieval payload. Do not put broker credentials, live account secrets, raw unrestricted news bodies, or an unlicensed document copy into the vector index. The vector record must be useless for authority without a successful PostgreSQL lookup that rechecks source permission, point-in-time validity, environment, correction state, and Strategy/Experiment scope.

`pgvector` supports exact search with perfect recall and approximate HNSW/IVFFlat search. Its documentation explicitly warns that approximate indexes can return different results, that filtered approximate queries can return too few rows because filtering is applied after index scanning, and that HNSW uses more memory and slower builds than IVFFlat. Start with exact search; if ANN is enabled, use iterative scans, oversampling plus exact reranking, and a recall benchmark against the exact query. [pgvector indexing and filtering](https://github.com/pgvector/pgvector)

## Point-in-time, correction, and deletion semantics

### Point-in-time reconstruction

Every canonical evidence record should carry at least:

- `observed_at`: when the source says the event/value occurred;
- `available_at`: when Market Mate could have obtained it under the source contract;
- `effective_at`: when the value applies to the instrument/account or policy;
- `received_at`: when the adapter received it;
- `recorded_at`: when the immutable row was accepted;
- `valid_from` and `valid_to`: the interpretation interval after corrections;
- `source_version`, `content_hash`, `parser_version`, and `calculation_version`.

Research and promotion queries must use `available_at` and the Decision-Time View, not the current corrected row. A replay must pin the evidence manifest, Data Contract, instrument/event-time definition, Indicator Definition, Model Version, Strategy Version, Policy Versions, and execution assumptions. A later correction may produce a new Corrected Research View and invalidate downstream evidence, but it cannot rewrite the old view.

PostgreSQL WAL and continuous archiving can restore a database to a chosen recovery target, while Iceberg snapshots provide table-level time travel for archive data. These are recovery/time-travel mechanisms, not substitutes for application-level point-in-time semantics. [PostgreSQL PITR](https://www.postgresql.org/docs/current/continuous-archiving.html), [Iceberg snapshots/time travel](https://iceberg.apache.org/docs/latest/branching/)

### Corrections and invalidation

1. Insert the correction/tombstone and its provenance in PostgreSQL; never overwrite the original observation or object manifest.
2. Mark dependent Research Snapshots, Indicator Observations, Sentiment Assessments, Experiment Trials, Decision Records, and vector records as affected using explicit lineage.
3. Remove or reindex vector records only after the canonical invalidation is committed. A vector service's asynchronous behavior cannot be used to claim that deletion or correction is complete.
4. If a Hard Indicator Dependency or Strategy-Grade Sentiment dependency is affected, disable dependent new exposure and follow the existing quarantine/revalidation contract. Existing positions remain under deterministic lifecycle and risk reduction authority.
5. Preserve the Decision-Time View, corrected view, correction reason, actor, timing, and source response. Never show a current semantic search result as if it were the evidence available at the historical decision.

### Licensed deletion

The Source Registry owns whether raw content, chunks, embeddings, summaries, backups, and derived models may survive a correction, deletion, account termination, or license expiry. For each source, implement a deletion manifest that names every PostgreSQL row, object version, vector ID, cache, backup, export, and model artifact affected. Where a provider permits retaining only a hash or metadata, retain that minimum evidence and mark the content unavailable. Where even derived artifacts must be deleted, purge them and preserve only the deletion event and whatever non-content audit metadata is contractually allowed.

Pinecone documents that record updates/deletes are eventually consistent, that deleted customer data may remain inaccessible but retained for up to 90 days before permanent deletion, and that audit events are retained for 90 days. That is a material reason a managed index cannot be the sole archive for licensed evidence or the canonical audit record. [Pinecone consistency/deletes](https://docs.pinecone.io/guides/manage-data/delete-data), [Pinecone data deletion](https://docs.pinecone.io/guides/production/data-deletion)

## Embedding versioning and deterministic replay

An embedding is a derived Model/Artifact Version, not a timeless property of a document. Pin all of the following:

- embedding provider/model identifier and model release or digest;
- dimensions, distance metric, normalization, tokenization, language, and truncation;
- chunking boundaries, overlap, field selection, redaction, and preprocessing code version;
- source content hash and canonical evidence ID;
- generated time, source availability time, and index build version;
- licensing scope for raw text, derived embeddings, summaries, and dashboard display.

Never update an embedding in place when any of those inputs change. Add a new row and new index membership, then retire the old row through a linked correction/rebuild event. A replay must be able to regenerate the vector from authorized canonical content or explicitly report `replay_unavailable` when a source contract requires deletion. A missing vector is an evidence state, not a neutral similarity score.

Use deterministic query manifests for every semantic retrieval used in research: query text/hash, query embedding version, filters, as-of timestamp, top-k, ANN parameters, exact-rerank setting, returned IDs/scores, and canonical records ultimately accepted by the agent. The dashboard should show the retrieval trace but should not imply that similarity equals probability, signal strength, or price direction.

## Paper/Live isolation and security

The safest initial arrangement is:

- separate PostgreSQL databases or schemas with separate roles for Paper and Live ledgers and account data;
- separate connection pools, credentials, queues, object prefixes/buckets, and vector indexes or namespaces;
- no vector service credential in the Safety Kernel or broker adapter;
- no Live account payload in a Paper retrieval namespace, and no Paper evidence silently labeled Live;
- application-level environment checks plus PostgreSQL row-level security and default-deny policies where shared infrastructure remains; PostgreSQL documents that RLS requires normal reads/writes to be allowed by an explicit policy and defaults to deny when no policy exists. [PostgreSQL row-level security](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
- a vector query returns only canonical IDs and derived scores; a trusted application service fetches and validates the authoritative record before display or research use;
- the order path has no dependency on a vector service. If the vector index is down, stale, out of date, or inconsistent, research degrades or dependent strategy evidence is disabled; trading safety and required deterministic risk controls continue from canonical stores.

Pinecone namespaces are useful for logical environment/tenant partitioning, and the provider documents physical separation within serverless namespaces. For Market Mate's higher-consequence Paper/Live boundary, use separate indexes or projects when the plan supports it and independently test the namespace/ACL contract; never treat a client-supplied namespace string as the only enforcement. [Pinecone multitenancy](https://docs.pinecone.io/guides/index-data/implement-multitenancy)

For backups and recovery:

- PostgreSQL uses encrypted snapshots plus WAL/PITR; restore into a new Environment Epoch and verify ledger invariants, hashes, row counts, policy versions, and source manifests before resuming.
- Object storage uses checksums, versioning, encryption, and a separate backup account or Trust Zone. S3 supports checksums to verify uploads/downloads. [S3 integrity checks](https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity.html)
- Vector indexes are backed up only as rebuild accelerators. A restore is valid only after comparing the index catalog to PostgreSQL and rerunning exact-recall, correction, deletion, and environment-isolation checks.
- A restore or failover never grants Live authority. The existing fail-closed recovery and authenticated Principal handback rules still apply.

## Scale, latency, and capacity assumptions

The current scope is bounded but time-series data can still become large. A first capacity model should measure actual bytes and row counts, using scenarios like these:

| Scenario | Illustrative annual volume before provider-specific compression |
|---|---:|
| Daily Research Snapshots: 50 securities × 252 sessions | 12,600 snapshots; typically metadata/JSON-sized, not a database-scale challenge |
| One-minute equity bars: 50 × 390 minutes × 252 sessions | 4.9 million bars; a few GB at compact normalized row widths, more with indexes and raw payloads |
| Daily option-chain observations: 50 × 100 contracts × 252 sessions | 1.26 million observations; multiplied by intraday cadence and contract universe |
| Embeddings: 126,000 evidence chunks × 1,536 dimensions | 0.72 GiB of raw vector values before metadata/index overhead; `pgvector` documents `4 * dimensions + 8` bytes per vector |
| Embeddings: 1 million chunks × 1,536 dimensions | 5.73 GiB of raw vector values before metadata/index overhead |

These are planning calculations, not forecasts. The daily research system should emit a monthly capacity report containing canonical row counts, compressed/uncompressed bytes, object count and bytes, vector count/dimensions, index size, backup/WAL volume, p50/p95/p99 query and ingest latency, ANN recall, correction/deletion lag, and fully loaded cost. The report must separate Paper, Live, and shared research data.

### Measurable gates

Use the following as starting gates; the Architecture and Data Entitlement decisions may tighten them after real measurements.

**Remain on plain PostgreSQL plus object storage while all are true:**

- no approved semantic retrieval use case is registered, or exact SQL/full-text search meets the research UX target;
- canonical PostgreSQL working set is below 20 GiB and 5 million normalized observation rows per environment, with at least 30% memory headroom after indexes and normal backup/reconciliation workload;
- daily ingestion completes within the approved research window and canonical writes have p95 under 250 ms without starving ledger/reconciliation operations;
- the archive remains below 250 GiB/year and bulk replay can complete within the declared research recovery window.

**Enable `pgvector` in a Research Trust Zone when any one of these is true and the semantic pilot is preregistered:**

- at least 10,000 authorized evidence chunks exist for which semantic retrieval is a defined research task; or
- exact lexical/structured retrieval misses the pilot's labeled relevance target; or
- a benchmark shows a repeated operator/agent workflow that requires similarity search and its acceptance criteria are explicit.

Start with exact nearest-neighbor search. Promote HNSW/IVFFlat only if a benchmark on a representative, filtered, point-in-time corpus records p95 retrieval at or below 500 ms, at least 99% recall@10 against exact search for the approved query set, no cross-environment leakage, and no violation of the canonical-ingest/reconciliation SLO. Re-run the recall benchmark after embedding-model, chunking, index, major PostgreSQL, or filter changes.

**Consider a separate managed vector service only when all are true:**

- the corpus exceeds 5 million active embeddings or 100 sustained semantic queries/second for a measured 30-day workload, or pgvector cannot meet the approved p95/recall SLO after index tuning and right-sizing;
- HNSW maintenance, memory pressure, or index build/recovery time materially interferes with canonical PostgreSQL SLOs, demonstrated in three repeatable load tests;
- the service supports the required region, encryption, access controls, backups, deletion/tombstone behavior, export/rebuild path, metrics, and cost caps;
- every vector record can be regenerated from PostgreSQL/object storage, and a provider outage or stale index causes a safe research fallback rather than a live authority decision;
- incremental fully loaded cost is approved as Operating Cost and remains inside the whole-experiment monthly and year-one ceilings.

These are decision gates, not entitlements. A smaller corpus may justify a dedicated service only for a proven security or operational requirement; a larger corpus may remain in `pgvector` if measured SLOs continue to hold.

## Cost model

The following are **illustrative storage-plane costs in USD**, using public list-price examples observed on 2026-08-21. They exclude broker fees, licensed market-data/news fees, model/embedding API fees, application compute, identity, messaging, development labor, tax, and egress not shown. The Architecture and Data Entitlement decisions must replace them with the selected cloud/region's quote before any commitment.

| Architecture | Illustrative monthly floor | Year-one floor | What is included / omitted |
|---|---:|---:|---|
| Plain PostgreSQL + small object archive | ~$15–$30 | ~$180–$360 | RDS `db.t4g.micro` compute example ($13.87/month) plus small storage/backups and ~100 GB S3 Standard; excludes HA, monitoring, transfer, and data licenses |
| PostgreSQL + `pgvector` | ~$20–$60 for Research/Paper | ~$240–$720 | Same database plus memory/storage headroom and vector-index backups; no separate vector subscription; production HA can be materially higher |
| PostgreSQL + Pinecone Builder | ~$35–$80 | ~$420–$960 | PostgreSQL/object floor plus Pinecone's $20/month Builder; usage beyond included plan limits and production backup/security features may change the result |
| PostgreSQL + Pinecone Standard | ~$65–$110 minimum | ~$780–$1,320 minimum | PostgreSQL/object floor plus Pinecone's $50/month minimum; pay-as-you-go usage, backup storage, and support add-ons can increase it |
| PostgreSQL + OpenSearch Serverless Classic | ~$365+ HA floor | ~$4,380+ | PostgreSQL/object floor plus 2 OCUs at the published $0.24/OCU-hour example; storage and transfer extra; dev/test mode is about $175.20/month for 1 total OCU but is not a production posture |
| Object storage/lakehouse archive only | ~$3–$30 per 100 GB–1 TB | ~$36–$360 | S3 Standard storage only at $0.023/GB-month; requests, replication, table compaction, catalog, query engine, and retrieval extra |

The cost conclusion is decisive: **the storage bytes are not the expensive part at the current universe size; operational complexity, data rights, market-data entitlement, embedding/model use, backups, and observability dominate.** A dedicated vector service can become economical at high retrieval volume, but its fixed subscription or minimum compute is disproportionate to a $1,000 trading experiment before measured need exists.

## Failure modes and controls

| Failure | Required behavior |
|---|---|
| PostgreSQL unavailable or transaction uncertain | No new authority or ledger acceptance. Preserve the request, retry idempotently, reconcile, and enter the existing uncertain/fail-closed state. |
| Object storage unavailable | Research ingestion pauses or records `Evidence Pending`; existing canonical decisions remain unchanged. Do not substitute a silently truncated payload. |
| Vector service unavailable/stale | Disable semantic retrieval or use exact PostgreSQL fallback. Never block required risk reduction, and never authorize new exposure from stale similarity results. |
| ANN returns incomplete/incorrect neighbors | Compare against exact search in validation; use oversampling/rerank and strict filters; record recall and mark retrieval degraded when the benchmark fails. |
| Correction/delete races vector upsert | Commit canonical tombstone first, mark vector `invalidated`, stop dependent use, then purge/rebuild. Eventual consistency never implies completed deletion. |
| Wrong Paper/Live environment | Separate credentials/indexes, database constraints/RLS, signed environment-bound manifests, negative tests, and fail-closed query checks. |
| Backup restore mixes epochs or histories | Restore into a new epoch; verify hashes, ledgers, row counts, correction lineage, policy versions, and vector catalog before any resume. |
| Provider lock-in or service termination | Export canonical PostgreSQL/object records; rebuild vectors from content hashes and pinned Model Versions; no provider-specific record can be the only copy. |
| Cost or query runaway | Per-tier budgets, forecasts, provider spend alerts, hard caps, automatic pause, and Principal-approved prospective expansion under the existing Operating Cost contract. |
| Untrusted text or prompt injection reaches retrieval | Treat all source text/metadata as data; sanitize/redact at ingestion; retrieval returns evidence references and structured fields, never executable instructions or authority. |

## Observability and acceptance evidence

The storage decision is not complete until the implementation can expose, per environment and trust zone:

- PostgreSQL transaction latency, deadlocks, lock waits, WAL/archive lag, PITR restore point, backup age, restore test result, replication/reconciliation lag, and row-level policy-denial events;
- object bytes/counts by source, retention class, region, encryption key, license state, version/tombstone state, failed checksum, lifecycle/deletion lag, and backup copy;
- vector count/bytes by model version, source, environment, and status; embedding generation failures; index build/rebuild time; exact-vs-ANN recall@k; query p50/p95/p99; stale/deletion lag; filter leakage tests; and provider/API errors;
- cost by component and category, forecast versus ceiling, overage/pause events, and allocation between Research, Paper, Live, and shared operations;
- every retrieval trace's canonical evidence IDs, as-of filter, source entitlement check, embedding/index versions, returned candidates, exact rerank result, and downstream Decision Record link;
- a daily integrity check and a scheduled restore/replay drill proving that the vector layer can be destroyed and reconstructed without changing canonical facts or authority.

## Staged recommendation

### Stage 0 — Contract before infrastructure

Resolve the sharp decisions listed below. Define the canonical schemas, object manifest, source-specific deletion/retention matrix, environment boundary, encryption/key custody, recovery objectives, budget ceilings, and retrieval SLO before selecting a cloud provider.

### Stage 1 — Research Evidence MVP

Implement plain PostgreSQL plus encrypted, versioned object storage. Prove daily point-in-time ingestion, Source Registry enforcement, raw/normalized manifests, Research Snapshots, correction/deletion handling, exact replay, Paper/Live isolation, dashboard lineage, backup/restore, and fully loaded cost reporting. Use SQL, JSONB, full-text, tags, and curated links for retrieval. Keep a no-vector fallback permanently.

### Stage 2 — Semantic retrieval pilot

Register one bounded semantic use case and labeled evaluation set. Add `pgvector` in the Research Trust Zone with exact search first. Record embedding Model Versions and retrieval traces. Compare exact/lexical, exact-vector, and ANN candidates; do not feed similarity directly to a Strategy Version until it passes the existing Indicator/Experiment/Strategy promotion contracts.

### Stage 3 — `pgvector` production qualification

Enable HNSW or IVFFlat only after recall, p95 latency, filter correctness, cost, rebuild, correction, and deletion tests pass. Keep vector rows derived and rebuildable. Promote semantic evidence only as a pinned input to a Strategy Version; retrieval still cannot authorize a trade.

### Stage 4 — Dedicated vector service evaluation

Open a new decision ticket only when the measured thresholds are reached. Compare Pinecone, OpenSearch/S3 Vectors, and any provider offered by the selected cloud using the same corpus, same filters, same deletion tests, same cost ceiling, and same outage/rebuild drill. Require export/rebuild evidence before production use. A service that cannot meet the source-license, audit, Paper/Live, and fail-closed contracts is rejected regardless of latency.

## Newly surfaced sharp decisions

This research resolves the architecture direction but surfaces these questions for the Wayfinder map:

1. **Canonical archive retention contract:** Which artifact classes may be retained indefinitely, which source-specific data must be purgeable, and what non-content audit evidence survives a provider deletion or contract termination?
2. **Cloud/region and key-custody choice:** Which cloud and region meet the Principal's cost, residency, managed Postgres, object-store, backup, IAM, and operational-usability requirements? Decide whether customer-managed keys are required for research, Paper, and Live separately.
3. **Initial retrieval contract:** Which dashboard, research, and agent workflows are allowed to use semantic retrieval, what labeled relevance set and p95/recall SLO apply, and which dependencies are Hard versus Soft when retrieval is unavailable?
4. **Embedding/data minimization policy:** Which source fields may be embedded, whether raw text may be retained in the vector index, which embedding providers/models are permitted, and how deletion/derivative rights are verified per Source Registry entry.
5. **Environment isolation level:** Are separate PostgreSQL databases and separate vector indexes mandatory for Paper and Live, or may schemas/namespaces be accepted after a concrete Trust Zone and negative-test review? The latter must never be assumed from co-location alone.
6. **Dedicated-service trigger approval:** Should the map adopt the proposed 5-million-vector/100-QPS/SLO-failure gates as defaults, or should the Architecture and Data Entitlement decisions set different limits based on the selected provider and measured costs?

## Final recommendation

Market Mate should use PostgreSQL plus object storage as its authoritative evidence foundation, introduce `pgvector` only for a measured and preregistered semantic-retrieval need, and defer a separate vector database until the system demonstrates a real scale or SLO problem. This yields transparent lineage, deterministic replay, safe correction/deletion handling, cloud portability, and a low-cost Research/Paper path while preserving a credible upgrade route if the repository genuinely becomes large.

The key architectural invariant is simple: **destroying every vector index must not destroy the evidence, change the ledger, alter a historical Decision Record, or grant or revoke trading authority.**

## Primary sources

- [PostgreSQL 18 MVCC and transaction consistency](https://www.postgresql.org/docs/current/mvcc-intro.html)
- [PostgreSQL table partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html)
- [PostgreSQL continuous archiving and PITR](https://www.postgresql.org/docs/current/continuous-archiving.html)
- [PostgreSQL row-level security](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
- [`pgvector` official README and source repository](https://github.com/pgvector/pgvector)
- [AWS RDS for PostgreSQL pricing](https://aws.amazon.com/rds/postgresql/pricing/)
- [AWS RDS getting-started cost example](https://docs.aws.amazon.com/AmazonRDS/latest/gettingstartedguide/rds-gsg.pdf)
- [AWS S3 pricing example](https://docs.aws.amazon.com/solutions/latest/live-streaming-on-aws-with-amazon-s3/cost-example-1.html)
- [AWS S3 Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html)
- [AWS S3 encryption](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingServerSideEncryption.html)
- [AWS S3 checksums and integrity](https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity.html)
- [AWS S3 Tables and Apache Iceberg](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables.html)
- [Apache Iceberg snapshot branching and time travel](https://iceberg.apache.org/docs/latest/branching/)
- [Amazon OpenSearch Service pricing](https://aws.amazon.com/opensearch-service/pricing/)
- [Amazon OpenSearch Serverless capacity limits](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/serverless-scaling.html)
- [Amazon S3 Vectors pricing](https://aws.amazon.com/s3/pricing/)
- [Google Cloud Storage pricing](https://cloud.google.com/storage/pricing)
- [Pinecone pricing](https://www.pinecone.io/pricing/)
- [Pinecone data freshness and deletion behavior](https://docs.pinecone.io/guides/manage-data/delete-data)
- [Pinecone security and backups](https://docs.pinecone.io/guides/production/security-overview)
- [Pinecone data deletion lifecycle](https://docs.pinecone.io/guides/production/data-deletion)
- [Pinecone multitenancy/namespaces](https://docs.pinecone.io/guides/index-data/implement-multitenancy)

