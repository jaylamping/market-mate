#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
project=market-mate-manual-requests-test
export MARKET_MATE_POSTGRES_PORT=15434
compose=(docker compose --project-name "$project")
mkdir -p evidence/incubator-manual-requests
worker_pid=''
cleanup() {
 if [[ -n "$worker_pid" ]]; then kill "$worker_pid" 2>/dev/null || true; wait "$worker_pid" 2>/dev/null || true; fi
 "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1
}
trap cleanup EXIT
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend --bin incubator-requests
env -i DATABASE_URL=postgres://mm:local-only@127.0.0.1:15434/market_mate ./target/debug/backend migrate
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate < db/fixtures/incubator_manual_requests_probe.sql > evidence/incubator-manual-requests/probe.log
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate < db/fixtures/incubator_manual_paid_models_probe.sql > evidence/incubator-manual-requests/paid-models-probe.log
# Create a check before startup; the actual HTTP submission and restart-safe worker
# run under the restricted identity, without provider credentials or network inference.
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate <<'SQL' > /dev/null
SET ROLE incubator_runner;
SELECT begin_incubator_request_check('worker-probe','{"title":"Worker recovery probe","text":"Compare a research premise with transaction costs","model":"vendor/model:free","selected_model":""}');
SELECT finish_incubator_request_check('worker-probe','{"complete":true,"matches":[],"issues":[]}');
SQL
env -i DATABASE_URL=postgres://incubator_runner:local-poc-only@127.0.0.1:15434/market_mate INCUBATOR_REQUESTS_BIND=127.0.0.1:18086 ./target/debug/incubator-requests > evidence/incubator-manual-requests/worker.log 2>&1 &
worker_pid=$!
python3 - <<'PY'
import hashlib,json,pathlib,time,urllib.request
base=pathlib.Path('evidence/incubator-manual-requests')
url='http://127.0.0.1:18086'
for _ in range(100):
 try:
  urllib.request.urlopen(url+'/healthz',timeout=1).close();break
 except OSError: time.sleep(.1)
else: raise AssertionError('request service did not start')
with urllib.request.urlopen(url+'/assignments/stream',timeout=10) as stream:
 first=json.loads(next(line[6:] for line in stream if line.startswith(b'data: ')))
 assert first['runs']==[]
 request=urllib.request.Request(url+'/assignments',data=json.dumps({'request_id':'worker-probe','accept_warning':False}).encode(),headers={'Content-Type':'application/json'})
 run=json.load(urllib.request.urlopen(request,timeout=5));assert run['state']=='admitted'
 final=None
 for line in stream:
  if line.startswith(b'data: '):
   runs=json.loads(line[6:])['runs']
   if runs and runs[0]['state']=='failed':final=runs[0];break
 assert final and [e['state'] for e in final['events']]==['admitted','failed']
 assert final['detail']['reason'] in ['model_not_whitelisted','credentials_unavailable','routing_policy_unavailable']
 again=json.load(urllib.request.urlopen(request,timeout=5));assert again['run_key']==run['run_key'] and again['state']=='failed'
report=[json.loads(l) for l in (base/'probe.log').read_text().splitlines() if l.startswith('{') and 'incubator-manual-requests' in l][-1]
assert report['passed']
report['checks']+=['catalog_token_limit_bounds','alternative_token_limit_similarity_dispatch','manual_paid_model_admission','manual_paid_model_idempotency','automatic_paid_model_denied','http_idempotency','durable_queue_worker','sse_initial_snapshot','sse_workflow_update','no_provider_dispatch_without_policy']
report['output_limits_migration_sha256']=hashlib.sha256(pathlib.Path('db/migrations/0063_incubator_model_output_limits.sql').read_bytes()).hexdigest()
report['model_identifier_migration_sha256']=hashlib.sha256(pathlib.Path('db/migrations/0062_manual_assignment_model_identifiers.sql').read_bytes()).hexdigest()
report['paid_model_migration_sha256']=hashlib.sha256(pathlib.Path('db/migrations/0061_manual_assignment_paid_models.sql').read_bytes()).hexdigest()
report['migration_sha256']=hashlib.sha256(pathlib.Path('db/migrations/0056_incubator_manual_assignments.sql').read_bytes()).hexdigest()
(base/'acceptance.json').write_text(json.dumps(report,indent=2)+'\n')
PY
kill "$worker_pid"
wait "$worker_pid" 2>/dev/null || true
worker_pid=''
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate <<'SQL' > /dev/null
SET ROLE incubator_runner;
SELECT begin_incubator_request_check('startup-probe','{"title":"Startup recovery","text":"Research a cost-aware stopping rule","model":"vendor/model:free","selected_model":""}');
SELECT finish_incubator_request_check('startup-probe','{"complete":true,"matches":[],"issues":[]}');
SELECT submit_incubator_request('startup-probe',false);
SQL
env -i DATABASE_URL=postgres://incubator_runner:local-poc-only@127.0.0.1:15434/market_mate INCUBATOR_REQUESTS_BIND=127.0.0.1:18086 ./target/debug/incubator-requests >> evidence/incubator-manual-requests/worker.log 2>&1 &
worker_pid=$!
python3 - <<'PYTEST'
import json,time,urllib.request
for _ in range(100):
 try:
  run=json.load(urllib.request.urlopen('http://127.0.0.1:18086/runs/manual-startup-probe',timeout=1))
  if run['state']=='failed':break
 except OSError:pass
 time.sleep(.1)
else:raise AssertionError('persisted assignment not picked up after restart')
assert [e['state'] for e in run['events']]==['admitted','failed']
PYTEST
kill "$worker_pid"
wait "$worker_pid" 2>/dev/null || true
worker_pid=''
DATABASE_URL=postgres://incubator_runner:local-poc-only@127.0.0.1:15434/market_mate cargo test --lib semantic_check_http_and_mid_batch_revocation -- --ignored --nocapture > evidence/incubator-manual-requests/semantic-test.log 2>&1
python3 - <<'PYTEST'
import json,pathlib
p=pathlib.Path('evidence/incubator-manual-requests/acceptance.json')
r=json.loads(p.read_text());r['checks']+=['startup_resumes_persisted_assignment_once','semantic_http_default_model','semantic_warning_requires_confirmation','approval_revocation_stops_next_batch']
p.write_text(json.dumps(r,indent=2)+'\n')
PYTEST
echo 'Manual assignment acceptance passed.'
