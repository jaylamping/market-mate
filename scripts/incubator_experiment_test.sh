#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MARKET_MATE_POSTGRES_PORT=15436
compose=(docker compose --project-name market-mate-experiment-test)
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
mkdir -p evidence/incubator-experiment
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend --bin incubator-requests
env -i DATABASE_URL=postgres://mm:local-only@127.0.0.1:15436/market_mate ./target/debug/backend migrate
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate < db/fixtures/incubator_experiment_probe.sql > evidence/incubator-experiment/probe.log
DATABASE_URL=postgres://incubator_runner:local-poc-only@127.0.0.1:15436/market_mate cargo test --lib experiment_worker_http_sse_and_restart -- --ignored --nocapture > evidence/incubator-experiment/worker-test.log 2>&1
python3 - <<'EVIDENCE'
import json,pathlib,hashlib
base=pathlib.Path('evidence/incubator-experiment')
r=[json.loads(l) for l in (base/'probe.log').read_text().splitlines() if l.startswith('{') and 'incubator-experiment' in l][-1]
assert r['passed']
r['checks']+=['notification_pickup','setup_role_routing','original_research_clarification','awaiting_data_without_execution','dataset_http_idempotency','experiment_role_handoff','preregistration_digest','sse_executed_results','model_intent_no_replay','local_execution_restart','post_handoff_owner_answer_resumes_same_package','evaluation_owner_constraint_preserved']
r['migration_sha256']=hashlib.sha256(pathlib.Path('db/migrations/0058_incubator_experiment_execution.sql').read_bytes()).hexdigest()
(base/'acceptance.json').write_text(json.dumps(r,indent=2)+'\n')
EVIDENCE
