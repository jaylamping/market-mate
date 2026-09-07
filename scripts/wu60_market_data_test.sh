#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MARKET_MATE_POSTGRES_PORT=15460
compose=(docker compose --project-name market-mate-wu60)
if [[ -n "$("${compose[@]}" ps -aq)" ]]; then
  echo 'market-mate-wu60 already exists; refusing to disturb it' >&2
  exit 1
fi
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
mkdir -p .scratch/wu60 evidence/wu-60
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend --bin market-data-download
env -i DATABASE_URL=postgres://mm:local-only@127.0.0.1:15460/market_mate ./target/debug/backend migrate > .scratch/wu60/migrations.log
cargo test --locked --lib market_data::tests -- --nocapture > .scratch/wu60/client-tests.log 2>&1
cargo test --locked --bin market-data-download > .scratch/wu60/output-tests.log 2>&1
./target/debug/market-data-download --help > .scratch/wu60/help.log
python3 - <<'CHECK'
import hashlib,json,pathlib,subprocess,tempfile
root=pathlib.Path.cwd()
client=(root/'.scratch/wu60/client-tests.log').read_text()
output=(root/'.scratch/wu60/output-tests.log').read_text()
checks=['paginated_download_has_explicit_feed_and_reproducible_panel','incomplete_duplicate_and_unexpected_data_never_make_a_panel','retry_and_access_errors_are_bounded_and_do_not_echo_provider_bodies','cyclic_pages_and_oversized_responses_are_rejected','date_identity_and_precision_validation','invalid_or_unfinished_request_makes_no_network_call']
for name in checks:
    assert f'test market_data::tests::{name} ... ok' in client, name
assert 'test tests::output_is_private_and_never_overwritten ... ok' in output
with tempfile.TemporaryDirectory() as d:
    target=pathlib.Path(d)/'panel.json'
    run=subprocess.run([str(root/'target/debug/market-data-download'),str(root/'docs/research/market-data-download-request.example.json'),str(target)],env={},capture_output=True,text=True)
    assert run.returncode!=0 and 'credentials_file_not_configured' in run.stderr
    assert not target.exists()
checks+=['private_atomic_output_no_overwrite','cli_missing_credentials_no_output','fresh_database_migrations']
files=['Cargo.lock','backend/src/market_data.rs','backend/src/market_data/tests.rs','backend/src/bin/market-data-download.rs','scripts/wu60_market_data_test.sh']
report={'work_unit':'WU-60','passed':True,'checks':checks,'live_provider_tested':False,'database_schema_changed':False,'source_sha256':{f:hashlib.sha256((root/f).read_bytes()).hexdigest() for f in files}}
(root/'evidence/wu-60/acceptance.json').write_text(json.dumps(report,indent=2)+'\n')
CHECK
