#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MARKET_MATE_POSTGRES_PORT=15439
compose=(docker compose --project-name market-mate-campaign-test)
if [[ -n "$("${compose[@]}" ps -aq)" ]]; then
  echo 'Refusing to reuse an existing campaign acceptance project.' >&2
  exit 1
fi
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
mkdir -p .scratch/campaign evidence/research-campaign
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend --bin incubator-requests
env -i DATABASE_URL=postgres://mm:local-only@127.0.0.1:15439/market_mate ./target/debug/backend migrate
cat db/fixtures/wu62_market_data_seed.sql db/fixtures/research_campaign_probe.sql db/fixtures/campaign_recovery_probe.sql db/fixtures/campaign_backlog_pickup_probe.sql db/fixtures/research_scout_retry_probe.sql db/fixtures/campaign_used_specs_probe.sql db/fixtures/campaign_exact_case_check_probe.sql | "${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate > .scratch/campaign/probe.log
python3 - <<'EVIDENCE'
import json,pathlib,hashlib,subprocess,urllib.request,urllib.error,time,os
worker=subprocess.Popen(['./target/debug/incubator-requests'],env={**os.environ,'DATABASE_URL':'postgres://incubator_runner:local-poc-only@127.0.0.1:15439/market_mate','INCUBATOR_REQUESTS_BIND':'127.0.0.1:15440'},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
try:
    url='http://127.0.0.1:15440/campaign'
    for attempt in range(50):
        try:
            state=json.load(urllib.request.urlopen(url,timeout=2)); break
        except OSError: time.sleep(.1)
    else: raise AssertionError('campaign API did not start')
    assert state['enabled'] is False and state['target']==10
    def save(revision):
        return urllib.request.urlopen(urllib.request.Request(url,data=json.dumps({'enabled':False,'daily_limit':10,'open_limit':3,'revision':revision,'creator_model':'','backlog_limit':10}).encode(),headers={'Content-Type':'application/json'}),timeout=5)
    assert json.load(save(0))['revision']==1
    try: save(0)
    except urllib.error.HTTPError as error: assert error.code==409
    else: raise AssertionError('stale API settings accepted')
finally:
    worker.terminate(); worker.wait(timeout=5)
# Run the capacity wait regression in the disposable database with a provider double.
subprocess.run(['cargo','test','campaign_','--','--ignored','--test-threads=1'],env={**os.environ,'DATABASE_URL':'postgres://incubator_runner:local-poc-only@127.0.0.1:15439/market_mate'},check=True)
r=[json.loads(l) for l in pathlib.Path('.scratch/campaign/probe.log').read_text().splitlines() if l.startswith('{') and '"probe": "research-campaign"' in l][-1]
assert r['passed']
assert any(json.loads(l).get('probe')=='campaign-recovery' and json.loads(l).get('passed') for l in pathlib.Path('.scratch/campaign/probe.log').read_text().splitlines() if l.startswith('{'))
assert any(json.loads(l).get('probe')=='campaign-backlog-pickup' and json.loads(l).get('passed') for l in pathlib.Path('.scratch/campaign/probe.log').read_text().splitlines() if l.startswith('{'))
assert any(json.loads(l).get('probe')=='research-scout-retry' and json.loads(l).get('passed') for l in pathlib.Path('.scratch/campaign/probe.log').read_text().splitlines() if l.startswith('{'))
assert any(json.loads(l).get('probe')=='campaign-used-specs' and json.loads(l).get('passed') for l in pathlib.Path('.scratch/campaign/probe.log').read_text().splitlines() if l.startswith('{'))
assert any(json.loads(l).get('probe')=='campaign-exact-case-check' and json.loads(l).get('passed') for l in pathlib.Path('.scratch/campaign/probe.log').read_text().splitlines() if l.startswith('{'))
r['checks']+=['linked_idempotent_retry','no_uncertain_retry','retry_preserves_pause_and_original','pre_dispatch_failure_visible','pause_cause_visible','creator_worker_preparation_failure_persisted','creator_storage_rejection_persisted']
r['checks']+=['campaign_paid_payload_fence','campaign_creator_role_fence','campaign_cancellation_pending_cost','http_campaign_read','http_campaign_save','http_stale_settings_rejected']
r['checks']+=['paused_backlog_pickup','topic_overlap_not_duplicate','exact_case_duplicate_queue','incomplete_check_auto_retry']
r['checks']+=['research_scout_retry','archived_research_not_retried','campaign_paid_research_claim','campaign_research_uses_free_runner','leftover_campaign_research_reroute']
r['checks']+=['assignment_used_spec_rejected']
r['checks']+=['campaign_exact_case_check']
r['checks']+=['campaign_paid_research_authorize']
r['sha256']={p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in ['db/migrations/0074_research_campaign.sql','db/migrations/0075_continuous_research_campaign.sql','db/migrations/0076_campaign_selected_spending.sql','db/migrations/0077_campaign_backlog_premise.sql','db/migrations/0078_campaign_failure_visibility.sql','db/migrations/0079_campaign_recovery.sql','db/migrations/0080_campaign_backlog_pickup.sql','db/migrations/0081_campaign_experiment_throughput.sql','db/migrations/0083_research_retry_campaign_paid.sql','db/migrations/0084_campaign_used_momentum_cases.sql','db/migrations/0085_campaign_exact_case_check.sql','db/migrations/0086_campaign_paid_research_authorize.sql','db/fixtures/campaign_recovery_probe.sql','db/fixtures/campaign_backlog_pickup_probe.sql','db/fixtures/research_scout_retry_probe.sql','db/fixtures/campaign_used_specs_probe.sql','db/fixtures/campaign_exact_case_check_probe.sql','backend/src/incubator_output.rs','backend/src/openrouter_request.rs','db/fixtures/research_campaign_probe.sql','backend/src/incubator.rs','backend/src/incubator_campaign.rs','backend/src/incubator_ticket_creator.rs','backend/src/incubator_requests.rs','backend/src/openrouter_capacity.rs','scripts/research_campaign_test.sh']}
pathlib.Path('evidence/research-campaign/acceptance.json').write_text(json.dumps(r,indent=2)+'\n')
EVIDENCE
