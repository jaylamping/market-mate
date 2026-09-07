#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MARKET_MATE_POSTGRES_PORT=15462
compose=(docker compose --project-name market-mate-wu62)
if [[ -n "$("${compose[@]}" ps -aq)" ]]; then echo 'WU-62 project exists; refusing to disturb it' >&2; exit 1; fi
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
mkdir -p .scratch/wu62 evidence/wu-62
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend --bin market-data-acquire
env -i DATABASE_URL=postgres://mm:local-only@127.0.0.1:15462/market_mate ./target/debug/backend migrate > .scratch/wu62/migrations.log
for probe in wu61_market_data_probe incubator_experiment_probe wu62_calendar_probe; do
 "${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate < "db/fixtures/$probe.sql" > ".scratch/wu62/$probe.log"
done
DATABASE_URL=postgres://mm:local-only@127.0.0.1:15462/market_mate cargo test --locked --lib market_data_acquisition::tests::acquisition_workflow -- --ignored --exact > .scratch/wu62/workflow.log 2>&1
./target/debug/market-data-acquire --help > .scratch/wu62/help.log
python3 - <<'CHECK'
import hashlib,json,pathlib
base=pathlib.Path('.scratch/wu62')
assert 'test market_data_acquisition::tests::acquisition_workflow ... ok' in (base/'workflow.log').read_text()
paths=['db/migrations/0064_market_data_acquisition.sql','db/migrations/0082_acquisition_commit_retry.sql','db/fixtures/wu62_market_data_seed.sql','db/fixtures/wu62_calendar_probe.sql','backend/src/market_data_acquisition.rs','backend/src/market_data_acquisition/tests.rs','backend/src/market_data.rs','backend/src/incubator_experiment.rs','scripts/wu62_market_data_test.sh']
r={'work_unit':'WU-62','passed':True,'checks':['calendar_closures_and_early_close','unsupported_requests_rejected','setup_to_executed_diagnostic','two_workers_one_lease','complete_cache_no_http','missing_symbol_fetch','missing_coverage_no_binding','explicit_retry','expired_lease_recovery','stale_worker_fenced','cancel_fences_commit','source_removal_fences_commit','restricted_runtime_role','audit_chain','wu61_and_legacy_regressions'],'source_sha256':{p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in paths},'live_provider_tested':False}
pathlib.Path('evidence/wu-62/acceptance.json').write_text(json.dumps(r,indent=2)+'\n')
CHECK
