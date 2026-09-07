#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MARKET_MATE_POSTGRES_PORT=15438
compose=(docker compose --project-name market-mate-refinement-test)
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
mkdir -p evidence/incubator-refinement
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend
env -i DATABASE_URL=postgres://mm:local-only@127.0.0.1:15438/market_mate ./target/debug/backend migrate
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate < db/fixtures/incubator_refinement_probe.sql > evidence/incubator-refinement/probe.log
python3 - <<'PY'
import json,pathlib,hashlib
p=pathlib.Path('evidence/incubator-refinement')
r=[json.loads(s) for s in (p/'probe.log').read_text().splitlines() if s.startswith('{') and '"probe"' in s][-1]
assert r['passed']
r['migration_sha256']=hashlib.sha256(pathlib.Path('db/migrations/0065_incubator_refinement.sql').read_bytes()).hexdigest()
r['archive_migration_sha256']=hashlib.sha256(pathlib.Path('db/migrations/0066_incubator_archived_refinement.sql').read_bytes()).hexdigest()
(p/'acceptance.json').write_text(json.dumps(r,indent=2)+'\n')
PY
