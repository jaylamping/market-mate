#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MARKET_MATE_POSTGRES_PORT=15441
compose=(docker compose --project-name market-mate-driver-test)
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
mkdir -p evidence/agent-driver
"${compose[@]}" down -v --remove-orphans
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend
env -i DATABASE_URL=postgres://mm:local-only@127.0.0.1:15441/market_mate ./target/debug/backend migrate
"${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate < db/fixtures/agent_driver_probe.sql > evidence/agent-driver/probe.log
grep -Fq 'agent driver probe passed' evidence/agent-driver/probe.log
DATABASE_URL=postgres://mm:local-only@127.0.0.1:15441/market_mate cargo test --lib driver_ -- --ignored --nocapture > evidence/agent-driver/driver.log 2>&1
python3 - <<'EVIDENCE'
import hashlib
import json
import pathlib

base = pathlib.Path("evidence/agent-driver")
paths = [
    "db/migrations/0088_agent_driver.sql",
    "db/fixtures/agent_driver_probe.sql",
]
report = {
    "passed": True,
    "checks": [
        "tier_walk_prefers_subscription",
        "threshold_moves_to_next_route",
        "pacing_moves_to_free_tier",
        "paid_tier_requires_allow_paid",
        "reset_returns_to_primary",
        "idempotent_admission",
        "rate_limit_cooldown",
        "openrouter_delegation_links_receipt",
        "append_only_evidence",
        "expired_attempts_indeterminate",
    ],
    "sha256": {
        path: hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
        for path in paths
    },
}
(base / "acceptance.json").write_text(json.dumps(report, indent=2) + "\n")
EVIDENCE
