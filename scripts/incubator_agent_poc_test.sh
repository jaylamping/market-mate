#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
project=market-mate-agent-poc-test
export MARKET_MATE_POSTGRES_PORT=15433
compose=(docker compose --project-name "$project")
mkdir -p evidence/incubator-agent-poc
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend
env -i DATABASE_URL=postgres://mm:local-only@127.0.0.1:15433/market_mate ./target/debug/backend migrate
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate \
  < db/fixtures/incubator_agent_poc_probe.sql > evidence/incubator-agent-poc/probe.log
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate \
  < db/fixtures/incubator_fallback_probe.sql > evidence/incubator-agent-poc/fallback-probe.log
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate \
  < db/fixtures/incubator_chat_probe.sql > evidence/incubator-agent-poc/chat-probe.log
python3 - <<'PY'
import hashlib,json,pathlib
base=pathlib.Path('evidence/incubator-agent-poc')
reports=[json.loads(line) for line in (base/'probe.log').read_text().splitlines() if line.startswith('{')]
assert len(reports)==1 and reports[0]['passed'] is True
reports[0]['migration_sha256']=hashlib.sha256(pathlib.Path('db/migrations/0053_incubator_agent_poc.sql').read_bytes()).hexdigest()
(base/'acceptance.json').write_text(json.dumps(reports[0],indent=2)+'\n')
fallback=[json.loads(line) for line in (base/'fallback-probe.log').read_text().splitlines() if line.startswith('{')]
assert len(fallback)==1 and fallback[0]['passed'] is True
fallback[0]['migration_sha256']=hashlib.sha256(pathlib.Path('db/migrations/0054_incubator_model_fallback.sql').read_bytes()).hexdigest()
(base/'fallback-acceptance.json').write_text(json.dumps(fallback[0],indent=2)+'\n')
chat=[json.loads(line) for line in (base/'chat-probe.log').read_text().splitlines() if line.startswith('{') and '"probe": "incubator-chat"' in line]
assert len(chat)==1 and chat[0]['passed'] is True
chat[0]['migration_sha256']=hashlib.sha256(pathlib.Path('db/migrations/0055_incubator_conversation.sql').read_bytes()).hexdigest()
(base/'chat-acceptance.json').write_text(json.dumps(chat[0],indent=2)+'\n')

PY
echo 'Incubator database acceptance passed.'
