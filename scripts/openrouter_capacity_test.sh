#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MARKET_MATE_POSTGRES_PORT=15440
compose=(docker compose --project-name market-mate-capacity-test)
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
mkdir -p evidence/openrouter-capacity
# Only the dedicated acceptance project's disposable database is reset.
"${compose[@]}" down -v --remove-orphans
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend
env -i DATABASE_URL=postgres://mm:local-only@127.0.0.1:15440/market_mate ./target/debug/backend migrate
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate < db/fixtures/openrouter_capacity_probe.sql > evidence/openrouter-capacity/probe.log
DATABASE_URL=postgres://mm:local-only@127.0.0.1:15440/market_mate cargo test --lib capacity_concurrent_admission -- --ignored --nocapture > evidence/openrouter-capacity/concurrency.log 2>&1
python3 - <<'EVIDENCE'
import json,pathlib,hashlib
base=pathlib.Path('evidence/openrouter-capacity')
assert '25 contenders, 1 permit, 20 minute commitments' in (base/'concurrency.log').read_text()
paths=['db/migrations/0068_openrouter_capacity.sql','db/migrations/0069_incubator_capacity_waits.sql','db/migrations/0070_openrouter_capacity_recovery.sql','db/fixtures/openrouter_capacity_probe.sql']
report={'passed':True,'checks':['free_daily_and_minute_account_limits','25_concurrent_contenders_one_remaining_slot','immutable_dispatch_no_replay','restricted_role_append_only_mechanisms','manual_paid_independent_of_automated_policy','prefer_free_models_toggle','bounded_paid_429_parent_attempts','unknown_cost_reservations_retained','expired_transport_slots_retired','prompt_fingerprints_only','request_substitution_rejected','queued_request_refresh_before_dispatch','late_success_preserves_newer_cooldown','workflow_intents_recover_despite_expired_capacity','numeric_job_prefix_isolation','unknown_commitment_visible_without_replay'],'sha256':{p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in paths}}
(base/'acceptance.json').write_text(json.dumps(report,indent=2)+'\n')
EVIDENCE
