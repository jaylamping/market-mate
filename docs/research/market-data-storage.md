# WU-61: governed local market-data storage

Implements the storage and registration step of the [data/graph plan](automatic-experiment-data-plan.md). The worker scheduler and automatic acquisition remain WU-62; source setup UI and daily housekeeping scheduling remain WU-63.

## Operations

Build `market-data-store` with Cargo or use the binary in the backend image. Set `MARKET_DATA_DATABASE_URL` to the local database login authorized for this operation. The new `market_data_writer` role is NOLOGIN and has function-only privileges; an administrator can grant it to the intended local service login. It has no direct table access or permission to call the legacy Incubator mutation functions. Incubator workers keep their existing role. No credentials or vendor agreements are created automatically.

```
market-data-store configure SOURCE_REGISTRY_VERSION_UUID ENTITLEMENT_VERSION_UUID
market-data-store import SOURCE_UUID DOWNLOAD.json
market-data-store list
market-data-store cleanup
market-data-store remove-source SOURCE_UUID
```

`configure` references existing effective Local Research source/entitlement versions; it never inserts a fictitious certification. Register actual account/plan terms through the existing source setup process first. A removed source configuration cannot be reactivated by repeating the command. Configuration for another approved version is a new source identity.

`import` accepts the WU-60 envelope. Rust rebuilds the panel from exact source observations, checks the request/content digests and fixed provider semantics, and rejects tampering. SQL independently checks panel coverage and raw-price consistency. These checks establish internal consistency, not cryptographic vendor authenticity. The returned UUID is the registered Research Snapshot; it appears in the existing dataset selector. Attaching it uses the existing manual UI until WU-62 automates the step.

## Storage and replay

`market_data_observation` retains decimal OHLC/volume, source version, symbol-mapping date and source bar identity. Identical observations are shared by multiple panels. A changed bar creates a new observation; pinned panels keep their previous values. These new records use the existing EOD field semantics but a separate deletable store because the older EOD tables embed append-only raw payloads. They are not inserted into the legacy EOD store and copied again.

`market_data_dataset` is the durable receipt/reference. `market_data_payload` holds the deletable panel, request, source facts and content digest. The Research Snapshot itself holds a reference and dataset class, not prices. Existing inline fixture snapshots continue to work. Managed payloads resolve through `read_incubator_experiment_input`.

Completed managed results are stored in `market_data_result`. The immutable Incubator event and audit chain contain a reference marker; read projections resolve it while available. This avoids keeping a second permanent copy of the price-derived calculations. Older inline experiments are unchanged; this is not a purge system for all historical application data.

Every import/bind/result/source-removal operation serializes on the configured source row. This prevents a source removal racing a new import or result publication. The runtime roles cannot directly edit the payloads or immutable audit history. The database administrator remains trusted.

## Retention and removal

`cleanup` expires panels unused for 90 days only when no experiment references them. Archived experiments retain their inputs. Shared observations survive until no retained panel uses them. The command is available now; daily invocation is added with WU-63.

`remove-source` is an explicit destructive operation: it stops subsequent imports for that configuration and removes all its active panels, source observations, membership links and managed results, including referenced experiments. Dataset/experiment identities and permitted non-content audit facts remain. Dataset lists exclude unavailable panels, input reads return no prices, result projections remove unavailable calculations, and the experiment explains that replay is unavailable. Other configured sources are unaffected.

This operation reports **active stores purged**, not complete deletion across every copy. The original download file, exports, existing client memory, PostgreSQL WAL and backups are outside its deletion scope. They must follow the provider's actual retention/deletion requirements separately. Restoring an old whole-database backup also restores old state: isolate restores and reapply current source removals before use. No claim of verified backup purge or cryptographic erasure is made. The initial 30-day backup recommendation is not implemented here.

## Verification

`bash scripts/wu61_market_data_test.sh` uses a separate Compose database, synthetic source/entitlement records and synthetic bars. It probes actual populated payload/observation/result deletion, function/table privileges, immutable result retries, idempotent registration, shared references, 90-day cleanup, source tombstones, replay projections, unrelated experiments and the audit hash chain. It also runs the legacy Incubator experiment SQL regression and the Rust untrusted-envelope tests. JSON evidence is in `evidence/wu-61/acceptance.json`.

No real market data, provider credentials or normal-project migrations are installed by the acceptance script.

Managed experiment messages and failure diagnostics are stored alongside deletable dataset payloads. Permanent events retain only validated control fields; projections resolve the full details while the source is available. Source removal also removes these details.
