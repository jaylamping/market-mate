#!/usr/bin/env bash
# PR1 acceptance: research contracts + artifact verification (map #171,
# decision #172). Isolated Compose project with its own ports; never touches
# the live project or database.
#
# Covers the map-Notes items in PR1 scope: invalid artifacts, missing
# critique, pinned-version replay, indeterminate dispatches, and unchanged
# cost controls. Memory admission (suspended/expired memory, unsupported
# lessons) belongs to PR2 and is not built here.
#
# Numbering note: this branch heads at migration 0095, so the contract
# migration lands as 0096 (the migrator requires contiguity). The head
# assertion below moves to 102 if later migrations merge first.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MARKET_MATE_POSTGRES_PORT=15441
project=market-mate-research-contract-test
compose=(docker compose --project-name "$project")
if [[ -n "$("${compose[@]}" ps -aq)" ]]; then
  echo 'Refusing to reuse an existing research-contract acceptance project.' >&2
  exit 1
fi
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
mkdir -p .scratch/research-contract evidence/research-contract
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend
# Clean environment like research_campaign_test.sh: the backend refuses to
# start when token-shaped variables leak into its environment.
env -i DATABASE_URL="postgres://mm:local-only@127.0.0.1:15441/market_mate" ./target/debug/backend migrate
head_version=$("${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate -c "SELECT max(version) FROM schema_migration;")
[[ "$head_version" == "96" ]] || { echo "expected migration head 96, got $head_version" >&2; exit 1; }
cat db/fixtures/research_contract_probe.sql | "${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate > .scratch/research-contract/probe.log
probe_line=$(grep '"probe": "research-contract"' .scratch/research-contract/probe.log | tail -n 1)
[[ -n "$probe_line" ]] || { echo 'research-contract probe emitted no result' >&2; exit 1; }
echo "$probe_line" | grep -q '"passed": true' || { echo 'research-contract probe failed' >&2; echo "$probe_line" >&2; exit 1; }
for check in admit_pins idempotent_admit reject_bad_pins record_manifest validity_gate reproducibility_gate readiness_gate \
  reject_bad_spec expired_assignment_invalid same_family_held missing_critique_held missing_dissent_held \
  same_assignment_or_run_held same_role_held pinned_replay_byte_identical diverged_digest_rejected \
  lineage_open_diverged indeterminate_preserved unknown_outcome_indeterminate failed_dispatch_diverged \
  unlinked_artifact_reproduces append_only insert_guard no_worker_grants; do
  echo "$probe_line" | grep -q "$check" || { echo "missing probe check $check" >&2; exit 1; }
done
cargo test --locked research_contract > .scratch/research-contract/cargo-test.log 2>&1
grep -q 'test result: ok' .scratch/research-contract/cargo-test.log || { echo 'research_contract module tests failed' >&2; exit 1; }
module_passed=$(grep -o '[0-9][0-9]* passed' .scratch/research-contract/cargo-test.log | head -n 1)
# PR1 ships no cost authority: the new behavior files must not reference
# provider cost admission or cost-bearing tiers. (This script's own canary
# text is excluded by only scanning the three behavior files.)
if grep -rniE 'openrouter_capacity' db/migrations/0096_research_contract.sql backend/src/research_contract.rs db/fixtures/research_contract_probe.sql; then
  echo 'cost-control surface leaked into PR1 behavior files' >&2; exit 1
fi
if grep -rniE 'allow_paid|paid_tier' db/migrations/0096_research_contract.sql backend/src/research_contract.rs db/fixtures/research_contract_probe.sql; then
  echo 'tier-cost surface leaked into PR1 behavior files' >&2; exit 1
fi
# The diff stays scoped: no tracked modification outside PR1 files may touch
# cost, model-policy, execution, or unrelated workflow paths.
if git status --porcelain | grep -E '^ ?M' | grep -Ei 'openrouter|capacity|paper|live|workspace|campaign|acquisition|market_data|paper\.rs'; then
  echo 'PR1 diff touches out-of-scope authority or workflow paths' >&2; exit 1
fi
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; fi
}
base_commit=$(git rev-parse HEAD)
cat > evidence/research-contract/acceptance.json <<EVIDENCE
{
  "status": "passed",
  "pr": "PR1 contracts + artifact verification (map #171, decision #172)",
  "base_commit": "$base_commit",
  "project": "$project",
  "postgres_port": 15441,
  "runtime": "isolated Compose postgres; no credentials or outbound model calls",
  "migrations": "1 through 96 applied to a fresh isolated database using the repository migrator",
  "module_tests": "cargo test --locked research_contract: $module_passed",
  "probe": $probe_line,
  "map_notes": {
    "invalid_artifacts": "bad pins, bad spec, authority claims, and diverged digests rejected",
    "missing_critique": "held, with same-family, same-role, same-run, and missing-dissent holds",
    "pinned_replay": "pinned-version replay reproduces byte-identical digests",
    "indeterminate_dispatches": "indeterminate and unknown outcomes stay indeterminate, never failed",
    "cost_controls_unchanged": "no provider cost admission or tier-cost references in PR1 behavior files"
  },
  "sha256": {
    "db/migrations/0096_research_contract.sql": "$(hash_file db/migrations/0096_research_contract.sql)",
    "backend/src/research_contract.rs": "$(hash_file backend/src/research_contract.rs)",
    "backend/src/lib.rs": "$(hash_file backend/src/lib.rs)",
    "db/fixtures/research_contract_probe.sql": "$(hash_file db/fixtures/research_contract_probe.sql)",
    "scripts/research_contract_test.sh": "$(hash_file scripts/research_contract_test.sh)"
  }
}
EVIDENCE
echo 'research-contract acceptance passed; evidence at evidence/research-contract/acceptance.json'
