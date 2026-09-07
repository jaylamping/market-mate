#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MARKET_MATE_POSTGRES_PORT=15461
compose=(docker compose --project-name market-mate-wu61)
if [[ -n "$("${compose[@]}" ps -aq)" ]]; then echo 'WU-61 project exists; refusing to disturb it' >&2; exit 1; fi
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
mkdir -p .scratch/wu61 evidence/wu-61
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend --bin market-data-store
env -i DATABASE_URL=postgres://mm:local-only@127.0.0.1:15461/market_mate ./target/debug/backend migrate > .scratch/wu61/migrations.log
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate < db/fixtures/wu61_market_data_probe.sql > .scratch/wu61/probe.log
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate < db/fixtures/incubator_experiment_probe.sql > .scratch/wu61/legacy-probe.log
cargo test --locked --lib market_data::tests > .scratch/wu61/client-tests.log 2>&1
./target/debug/market-data-store --help > .scratch/wu61/help.json
MARKET_DATA_DATABASE_URL=postgres://mm:local-only@127.0.0.1:15461/market_mate ./target/debug/market-data-store list > .scratch/wu61/catalog.json
python3 - <<'CHECK'
import hashlib,json,pathlib
base=pathlib.Path('.scratch/wu61')
r=[json.loads(line) for line in (base/'probe.log').read_text().splitlines() if line.startswith('{') and 'WU-61' in line][-1]
assert r['passed']
assert json.loads((base/'catalog.json').read_text())==[]
assert 'test market_data::tests::saved_download_rejects_panel_tampering_and_extra_provenance ... ok' in (base/'client-tests.log').read_text()
legacy=[json.loads(line) for line in (base/'legacy-probe.log').read_text().splitlines() if line.startswith('{') and 'incubator-experiment' in line][-1]
assert legacy['passed']
r['checks']+=['untrusted_envelope_validation','cli_database_read','legacy_experiment_regression']
r['source_sha256']={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [pathlib.Path('db/migrations/0060_market_data_storage.sql'),pathlib.Path('db/fixtures/wu61_market_data_probe.sql'),pathlib.Path('backend/src/market_data.rs'),pathlib.Path('backend/src/bin/market-data-store.rs'),pathlib.Path('scripts/wu61_market_data_test.sh')]}
r['live_provider_tested']=False
r['external_backups_purged']=False
pathlib.Path('evidence/wu-61/acceptance.json').write_text(json.dumps(r,indent=2)+'\n')
CHECK
