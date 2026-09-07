#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MARKET_MATE_POSTGRES_PORT=15438
compose=(docker compose --project-name market-mate-archive-test)
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
mkdir -p evidence/incubator-research-archive
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend --bin incubator-requests
env -i DATABASE_URL=postgres://mm:local-only@127.0.0.1:15438/market_mate ./target/debug/backend migrate
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate < db/fixtures/incubator_research_archive_probe.sql > evidence/incubator-research-archive/probe.log
DATABASE_URL=postgres://incubator_runner:local-poc-only@127.0.0.1:15438/market_mate cargo test --lib archive_http_sse_and_restore -- --ignored --nocapture > evidence/incubator-research-archive/worker-test.log 2>&1
python3 - <<'EVIDENCE'
import json,pathlib,hashlib
base=pathlib.Path('evidence/incubator-research-archive')
r=[json.loads(l) for l in (base/'probe.log').read_text().splitlines() if l.startswith('{') and 'incubator-research-archive' in l][-1]
assert r['passed']
r['checks']+=['archive_http_idempotency','sse_archive_update','restore_http','delayed_http_replay_no_effect','direct_link_preserved']
r['migration_sha256']=hashlib.sha256(pathlib.Path('db/migrations/0059_incubator_research_archive.sql').read_bytes()).hexdigest()
(base/'acceptance.json').write_text(json.dumps(r,indent=2)+'\n')
EVIDENCE
