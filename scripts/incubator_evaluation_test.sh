#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MARKET_MATE_POSTGRES_PORT=15435
compose=(docker compose --project-name market-mate-evaluation-test)
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
mkdir -p evidence/incubator-evaluation
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend --bin incubator-requests
env -i DATABASE_URL=postgres://mm:local-only@127.0.0.1:15435/market_mate ./target/debug/backend migrate
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate < db/fixtures/incubator_evaluation_probe.sql > evidence/incubator-evaluation/probe.log
DATABASE_URL=postgres://incubator_runner:local-poc-only@127.0.0.1:15435/market_mate cargo test --lib evaluation_worker_http_sse_and_restart -- --ignored --nocapture > evidence/incubator-evaluation/worker-test.log 2>&1
python3 - <<'EVIDENCE'
import json,pathlib,hashlib
base=pathlib.Path('evidence/incubator-evaluation')
r=[json.loads(l) for l in (base/'probe.log').read_text().splitlines() if l.startswith('{') and 'incubator-evaluation' in l][-1]
assert r['passed']
r['checks']+=['worker_automatic_evaluation','original_model_clarification','repeated_question_escalation','owner_answer_http_idempotency','sse_experiment_creation','orphan_dispatch_no_replay']
r['migration_sha256']=hashlib.sha256(pathlib.Path('db/migrations/0057_incubator_evaluation.sql').read_bytes()).hexdigest()
(base/'acceptance.json').write_text(json.dumps(r,indent=2)+'\n')
EVIDENCE
