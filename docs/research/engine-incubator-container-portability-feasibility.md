# Engine and Incubator container portability feasibility

Research date: 2026-08-25
Status: planning contract; no runtime or cloud platform is selected

## Decision objective

Determine whether the Engine and Incubator can move from a local Research installation to a cloud Paper installation without changing their economic behavior, evidence identities, or authority boundaries. This decision covers packaging and portability only. It does not select a cloud, scheduler, database, secret manager, broker, or Live architecture, and it grants no trading authority.

## Repository evidence and present limit

The canonical repository currently contains the product glossary, research dossiers, and a static Audit Dashboard prototype. It does not yet contain an Engine or Incubator runtime, dependency lock, container manifest, database migration, queue contract, or executable conformance suite. A production image therefore cannot be built or benchmarked from current repository evidence. Feasibility is accepted only as a testable packaging contract; implementation readiness remains unproven.

## Accepted boundary

The portable unit is a signed, immutable **Workload Release**, not a copied developer machine or a mutable long-running agent session. Each Engine or Incubator process must run as an unprivileged, read-only-root workload with:

- a declared architecture, runtime, entry point, dependency lock, configuration schema, health contract, and resource envelope;
- no embedded credentials, research payloads, mutable memory, host paths, Docker socket, privileged mode, or infrastructure-administration capability;
- explicit network destinations and separate workload identities for Engine orchestration, Incubator Research, and Incubator Paper work;
- durable state outside the container in versioned stores and queues, addressed through typed interfaces;
- ephemeral scratch space that can be destroyed without losing canonical evidence, budget attribution, assignment state, or liveness; and
- a content digest, source revision, build provenance, software bill of materials, vulnerability result, signature, and compatibility manifest.

Engine and Incubator may share a physical host during Local Research or approved Paper work, but co-location never merges their identities, queues, data permissions, or authority. Paper and Live credentials, queues, ledgers, and records cannot be mounted into a Research workload. No Workload Release may contain broker withdrawal capability or direct authority to widen a policy, budget, entitlement, or lifecycle state.

## Local-to-cloud portability contract

The same Workload Release digest must pass the same conformance fixtures locally and in the candidate cloud environment. Environment-specific deployment descriptions may bind endpoints, identities, storage classes, and resource limits, but may not rebuild dependencies or change application code. A configuration change that can alter economic results, evidence visibility, scheduling, cost, or authority is versioned evidence and requires replay of its affected fixtures.

Portable behavior includes:

1. deterministic parsing, validation, artifact hashing, idempotency, and typed handoffs;
2. preservation of assignment, source, model, policy, budget, environment, and time identities;
3. equivalent fail-closed behavior for missing configuration, identity, entitlement, evidence, and downstream dependencies;
4. graceful interruption at declared checkpoints, followed by idempotent restart or explicit containment rather than hidden continuation;
5. UTC storage plus original source and receipt times, with clock uncertainty surfaced rather than normalized away; and
6. bounded CPU, memory, disk, network, concurrency, and external spend that cannot be enlarged by the workload itself.

Stochastic model output need not be byte-identical when the declared provider cannot guarantee it. In that case the fixture must replay a captured, authorized response or assert a versioned invariant over the output. A portability claim may never disguise model, provider, architecture, numerical-library, or prompt drift as an environment difference.

## State, delivery, and recovery

Every assignment has a stable identity and an idempotency boundary. Delivery is at least once; consumers deduplicate by canonical identity and record conflicting reuse as an integrity failure. Acknowledgement occurs only after the produced artifact and its lineage are durable. Lease expiry may make work eligible for another attempt, but concurrent or late results remain separately attributable and cannot overwrite each other.

A workload termination must leave one of three observable results: a durable completed artifact, a durable retry-safe checkpoint, or a Decision Liveness Record naming the blocked scope and safe continuation. Deployment replacement drains or fences old work before the new release consumes it. Rollback deploys a previously verified digest; it never rewrites artifacts produced by the superseded release.

Backups, restore tests, queue redelivery, database migrations, and disaster recovery belong to the later architecture decision. This contract requires their interfaces to preserve immutable evidence identities and environment separation; it does not claim that current repository contents implement them.

## Supply-chain and host controls

Builds use a pinned base-image digest and locked application dependencies in an isolated CI identity. The build emits provenance and an SBOM, scans both operating-system and application dependencies, signs the resulting digest, and promotes that exact digest between environments. Deployment verifies the signature and approved provenance before startup. Floating tags, in-place package installation, and environment rebuilds are prohibited for qualified releases.

The host or orchestrator enforces user namespaces or an equivalent non-root boundary, a default-deny network policy, read-only filesystems, bounded writable scratch space, dropped Linux capabilities, syscall restrictions, and resource limits. Infrastructure administrators remain separate from Application Administration. Container isolation reduces accidental coupling but is not accepted as the sole Live Trust Zone boundary; the architecture decision must assess host, kernel, control-plane, registry, signing-key, and administrator compromise.

## Conformance gates

A candidate implementation is portable only when all of the following evidence is attached to one release digest:

| Gate | Required evidence | Failure effect |
|---|---|---|
| Reproducible package | Two isolated builds resolve to the same digest, or every attested nondeterministic field is explained and excluded from executable content | Release is unqualified |
| Runtime contract | Clean startup, health, graceful termination, forced termination, retry, and duplicate-delivery fixtures pass | Affected workload cannot deploy |
| State independence | Container deletion and replacement lose no canonical artifact and create no hidden duplicate | Paper advancement is blocked |
| Environment parity | Identical captured inputs produce identical deterministic artifacts and equivalent invariant results locally and in cloud | Migration is blocked |
| Isolation | Negative tests deny undeclared files, secrets, networks, queues, databases, broker capabilities, and privileged host interfaces | Affected Trust Zone is unqualified |
| Resource containment | CPU, memory, disk, concurrency, network, and spend limits stop or queue work without corrupting evidence | Release is unqualified |
| Supply chain | Pinned dependencies, SBOM, vulnerability disposition, provenance, signature, and admission verification are complete | Deployment is denied |
| Observability | Logs, metrics, traces, costs, and liveness preserve assignment and release identities without secrets or restricted source payloads | Qualification is blocked |
| Recovery | Drain, crash, redelivery, rollback, migration, and restored-state tests preserve lineage and expose uncertainty | Cloud Paper remains disabled |

The initial feasibility experiment should use a credential-free synthetic assignment, a local container runtime, and one disposable cloud Paper sandbox. It must exercise interruption, duplicate delivery, denied egress, dependency outage, resource exhaustion, and rollback. Broker credentials, licensed production data, and Live records are expressly outside that experiment.

## Decision and dependency effect

Containerized local-to-cloud portability is feasible in principle under this contract, but the current repository cannot yet demonstrate implementation feasibility. The architecture decision may rely on the packaging, state, identity, and conformance boundaries above. It must still select and cost the runtime, registry, scheduler, state stores, queues, identity system, observability path, signing custody, recovery design, and Trust Zone deployment topology.

This conclusion does not certify a container runtime, permit cloud deployment, or remove any Compliance Policy, managed-identity, Safety Kernel, data-entitlement, Paper-certification, or stage-applicability gate.

## Implementation handoff

Before executable work begins, create repository-owned fixtures for the synthetic assignment and its expected lineage, then add:

1. locked runtime dependencies and an architecture-specific build declaration;
2. separate Engine and Incubator entry points and workload identities;
3. configuration schemas with safe missing-value behavior;
4. typed state and queue adapters with duplicate and conflict fixtures;
5. a hermetic image build, SBOM, provenance, signing, scanning, and verification path; and
6. a local/cloud conformance runner that emits one immutable **Portability Evidence Bundle** per release digest.

No acceptance item may be satisfied solely by a successful container start, a manual demonstration, or an image tag.
