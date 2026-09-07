#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MARKET_MATE_POSTGRES_PORT=15463
compose=(docker compose --project-name market-mate-wu63)
if [[ -n "$("${compose[@]}" ps -aq)" ]]; then echo 'WU63 project exists; refusing to disturb it' >&2; exit 1; fi
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
mkdir -p .scratch/wu63 evidence/wu-63
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend --bin market-data-service
env -i DATABASE_URL=postgres://mm:local-only@127.0.0.1:15463/market_mate ./target/debug/backend migrate > .scratch/wu63/migrations.log
for probe in wu61_market_data_probe incubator_experiment_probe wu62_calendar_probe wu63_market_data_setup_probe market_data_setup_revisit_probe setup_response_recovery_probe; do
 "${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate < "db/fixtures/$probe.sql" > ".scratch/wu63/$probe.log"
done
DATABASE_URL=postgres://mm:local-only@127.0.0.1:15463/market_mate cargo test --locked --lib market_data_connection::tests::setup_and_refresh -- --ignored --exact > .scratch/wu63/workflow.log 2>&1
python3 - <<'CHECK'
import hashlib,json,pathlib
assert 'test market_data_connection::tests::setup_and_refresh ... ok' in pathlib.Path('.scratch/wu63/workflow.log').read_text()
paths=['db/migrations/0073_experiment_spec_echo.sql','db/migrations/0072_setup_response_recovery.sql','db/fixtures/setup_response_recovery_probe.sql','backend/src/openrouter_request.rs', 'db/migrations/0071_market_data_setup_revisit.sql','db/fixtures/market_data_setup_revisit_probe.sql','backend/src/incubator_experiment.rs','db/migrations/0067_market_data_setup_refresh.sql','db/fixtures/wu63_market_data_setup_probe.sql','backend/src/market_data_connection.rs','backend/src/market_data_connection/tests.rs','backend/src/market_data_acquisition.rs','scripts/wu63_market_data_test.sh']
r={'work_unit':'WU-63','passed':True,'checks':['owner_account_review_required','historical_provider_check','private_credentials_no_status_leak','owner_request_idempotency','collection_pause','calendar_morning_refresh','holiday_and_preopen_skip','catchup_window','repeat_schedule_dedup','original_snapshot_preserved','paused_refresh_fence','archived_research_stops','restricted_roles','audit_chain','legacy_regressions','setup_revisit_on_connector_availability','revisit_download_to_diagnostic','revisit_pause_archive_fences','revisit_question_no_loop','concurrent_revisit_once','revisit_context_survives_clarification','revisit_respects_capacity_wait','revisit_owner_answer_to_completion','confirmed_setup_retry_once','retry_download_to_completion','retry_archive_and_budget_fences','identical_execute_spec_echo_recovery','changed_execute_spec_rejected'],'source_sha256':{p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in paths},'live_provider_tested':False}
pathlib.Path('evidence/wu-63/acceptance.json').write_text(json.dumps(r,indent=2)+'\n')
CHECK
