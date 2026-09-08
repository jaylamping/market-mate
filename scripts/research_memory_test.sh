#!/usr/bin/env bash
# PR2 acceptance: Institutional Memory admission + containment (map #171,
# decision #173, rollout #176). Isolated Compose project with its own ports;
# never touches the live project or database.
#
# Covers the map-Notes items in PR2 scope: unsupported lessons (missing
# lineage, non-disjoint support, self-review), suspended/expired memory,
# pinned-version retrieval, and unchanged cost controls. Recipe/retrieval
# integration belongs to PR3 and measurement to PR4; neither is built here.
#
# Numbering note: this branch heads at migration 0096, so the memory
# migration lands as 0097 (the migrator requires contiguity). The head
# assertion below moves to 103 if later migrations merge first.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MARKET_MATE_POSTGRES_PORT=15443
project=market-mate-research-memory-test
compose=(docker compose --project-name "$project")
if [[ -n "$("${compose[@]}" ps -aq)" ]]; then
  echo 'Refusing to reuse an existing research-memory acceptance project.' >&2
  exit 1
fi
trap '"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1' EXIT
mkdir -p .scratch/research-memory evidence/research-memory
"${compose[@]}" up -d --wait postgres
cargo build --locked --bin backend
# Clean environment like research_campaign_test.sh: the backend refuses to
# start when token-shaped variables leak into its environment.
env -i DATABASE_URL="postgres://mm:local-only@127.0.0.1:15443/market_mate" ./target/debug/backend migrate
head_version=$("${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate -c "SELECT max(version) FROM schema_migration;")
[[ "$head_version" == "97" ]] || { echo "expected migration head 97, got $head_version" >&2; exit 1; }
cat db/fixtures/research_memory_probe.sql | "${compose[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U mm -d market_mate > .scratch/research-memory/probe.log
probe_line=$(grep '"probe": "research-memory"' .scratch/research-memory/probe.log | tail -n 1)
[[ -n "$probe_line" ]] || { echo 'research-memory probe emitted no result' >&2; exit 1; }
echo "$probe_line" | grep -q '"passed": true' || { echo 'research-memory probe failed' >&2; echo "$probe_line" >&2; exit 1; }
# A1: probe asserts_run must meet the hardcoded floor. ASSERTS_MIN is the
# number of `PERFORM pg_temp.contract_assert` call sites in the probe fixture,
# computed once via: grep -c 'PERFORM pg_temp.contract_assert' db/fixtures/research_memory_probe.sql
# (89 at the time of this fix). The counter is threaded through the probe via
# a TEMP sequence (non-transactional nextval survives ROLLBACK) and emitted as
# "asserts_run"; self-reported passed:true alone is not trusted. Keep the
# full-name check below too.
ASSERTS_MIN=89
asserts_run=$(echo "$probe_line" | grep -o '"asserts_run": [0-9][0-9]*' | grep -o '[0-9][0-9]*' | head -n 1)
[[ -n "$asserts_run" ]] || { echo 'research-memory probe emitted no asserts_run' >&2; echo "$probe_line" >&2; exit 1; }
[[ "$asserts_run" -ge "$ASSERTS_MIN" ]] || { echo "research-memory probe ran $asserts_run asserts, expected >= $ASSERTS_MIN" >&2; echo "$probe_line" >&2; exit 1; }
expected_checks="pure_provenance_accepts_full_lineage pure_provenance_rejects_missing_lineage pure_support_accepts_disjoint pure_support_rejects_self_review pure_support_rejects_shared_session pure_support_rejects_repeated_assignment reject_critic_session_model_reuse pure_scope_accepts_all_types pure_scope_rejects_malformed pure_dissent_accepts_versioned pure_guidance_admits_methods pure_guidance_rejects_gate_change pure_guidance_rejects_spaced_keys pure_guidance_rejects_plural propose_lesson propose_idempotent propose_timezone_idempotent reject_changed_inputs reject_changed_source_lineage reject_missing_lineage reject_nondisjoint_support reject_self_review_support reject_shared_session_support reject_gate_change_guidance reject_unknown_provenance_assignment reject_unknown_source_artifact reject_own_lineage_support admit_lesson admit_idempotent reject_admit_unknown reject_admit_after_expiry contain_proposed_suspend contain_proposed_contaminate contain_proposed_expire retrieve_admitted_global retrieve_role_posture_scoped retrieve_method_data_scoped retrieve_blocks_expired_at suspend_blocks_retrieval supersede_resolves_to_successor reject_supersede_proposed_successor reject_supersede_cycle contaminate_blocks_retrieval reject_contaminate_without_reason expire_blocks_retrieval reject_illegal_transition reject_illegal_transition_with_flag reject_direct_write_with_flag reject_unknown_successor duplicate_links_canonical reject_duplicate_reused_support reject_duplicate_suspended_canonical pinned_review_flags pinned_review_flags_stale_version pinned_review_flags_malformed dissent_versioned_preserved append_only insert_guard no_worker_grants"
emitted_sorted=$(echo "$probe_line" | grep -o '"checks": \[[^]]*\]' | grep -o '"[a-z_0-9][a-z_0-9]*"' | tr -d '"' | grep -v '^checks$' | sort)
expected_sorted=$(echo "$expected_checks" | tr ' ' '\n' | sort)
if [[ "$emitted_sorted" != "$expected_sorted" ]]; then
  echo 'research-memory probe checks mismatch' >&2
  echo '--- emitted ---' >&2
  echo "$emitted_sorted" >&2
  echo '--- expected ---' >&2
  echo "$expected_sorted" >&2
  echo '--- diff ---' >&2
  diff <(echo "$emitted_sorted") <(echo "$expected_sorted") >&2 || true
  exit 1
fi
cargo test --locked research_memory > .scratch/research-memory/cargo-test.log 2>&1
grep -q 'test result: ok' .scratch/research-memory/cargo-test.log || { echo 'research_memory module tests failed' >&2; exit 1; }
module_passed=$(grep -o '[0-9][0-9]* passed' .scratch/research-memory/cargo-test.log | head -n 1)
# A6: pin the exact module-test count (changes with new tests; update here and
# in the evidence template expectation when adding tests). Currently 28 after
# B1/B3/B4/B7/S2/S3 Rust regressions (22 baseline + 6 new).
[[ "$module_passed" == "28 passed" ]] || { echo "research_memory module tests count mismatch: got '$module_passed', expected '28 passed'" >&2; exit 1; }
# PR2 ships no cost authority: the new behavior files must not reference
# provider cost admission or cost-bearing tiers. (This script's own canary
# text is excluded by only scanning the three behavior files.)
if grep -rniE 'openrouter_capacity' db/migrations/0097_memory_admission.sql backend/src/research_memory.rs db/fixtures/research_memory_probe.sql; then
  echo 'cost-control surface leaked into PR2 behavior files' >&2; exit 1
fi
if grep -rniE 'allow_paid|paid_tier' db/migrations/0097_memory_admission.sql backend/src/research_memory.rs db/fixtures/research_memory_probe.sql; then
  echo 'tier-cost surface leaked into PR2 behavior files' >&2; exit 1
fi
# The diff stays scoped: PR2 leaves changes uncommitted, so the guard covers
# the union of the committed PR range and the working tree (excluding test
# evidence outputs), against the PR2 allowlist. Plus a content scan of the
# behavior files for cost/execution authority. Behavior paths only, so this
# script's own canary text is excluded. The probe fixture intentionally
# contains authority negatives (rejection tests) and the Rust deny-list
# constant contains the rejected keys as data, so the execution-authority
# scan covers migration+Rust production lines with those known-good
# deny/test literals excluded via exact full-line allowlisting (A2, not
# substring grep -v which suffers suffix bypass). Rust unit tests must also
# contain forbidden literals as rejection fixtures (asserting the scanner
# rejects them), so test-module lines (at/after `mod tests`) are excluded
# from this scan — production code above it is fully scanned.
# A6: evidence trust comes from the rerun flow that regenerates
# evidence/research-memory/acceptance.json below; hand-editing the evidence
# file without rerunning this script is not trusted (hashes would mismatch).
base=$(git merge-base origin/main HEAD)
# A6: diff-filter default includes deletions (no --diff-filter flag), so
# deleted files cannot silently escape the allowlist.
committed=$(git diff --name-only "$base"..HEAD)
worktree_changed=$(git status --porcelain | sed 's/^...//' | sed 's/.* -> //')
changed=$(printf '%s\n%s' "$committed" "$worktree_changed" | grep -v '^$' | grep -v '^evidence/' | grep -v '^\.scratch/' | sort -u)
echo "PR2 changed files vs $base (committed range plus working tree):"
echo "$changed"
# B3 requires backend/src/research_contract.rs (AUTHORITY_KEYS pub(crate) for
# GATE_CHANGE_KEYS cross-check); it is in-scope for the admission boundary.
allow='^(db/migrations/0097_memory_admission\.sql|backend/src/research_memory\.rs|backend/src/research_contract\.rs|backend/src/lib\.rs|db/fixtures/research_memory_probe\.sql|scripts/research_memory_test\.sh)$'
if echo "$changed" | grep -Ev "$allow" | grep -q .; then
  echo 'PR2 diff touches files outside the PR2 allowlist' >&2; exit 1
fi
if echo "$changed" | grep -Ei 'openrouter|capacity|paper|live|workspace|campaign|acquisition|market_data'; then
  echo 'PR2 diff touches out-of-scope authority or workflow paths' >&2; exit 1
fi
if grep -h -rniE 'openrouter_capacity|allow_paid|paid_tier' db/migrations/0097_memory_admission.sql backend/src/research_memory.rs db/fixtures/research_memory_probe.sql; then
  echo 'cost authority leaked into PR2 behavior files' >&2; exit 1
fi
# A4: fail closed if `mod tests` is missing/misplaced; anchor on the
# declaration line so comments/strings cannot spoof the split.
test_start=$(grep -n '^[[:space:]]*mod tests' backend/src/research_memory.rs | head -n 1 | cut -d: -f1)
[[ -n "$test_start" ]] || { echo 'research_memory.rs has no `mod tests` declaration; failing closed' >&2; exit 1; }
rust_nontest=$(awk -v start="$test_start" 'NR < start - 1' backend/src/research_memory.rs)
# A3: include the lib.rs diff hunk in content scans; it must contain only the
# mod line (no cost/execution authority). The committed+worktree lib.rs diff
# is scanned alongside production lines.
lib_diff=$(git diff "$base"..HEAD -- backend/src/lib.rs; git diff -- backend/src/lib.rs)
# lib.rs must only add the research_memory mod line (plus blank/context);
# reject any other content. Allow diff headers, blank additions, and the
# single `pub(crate) mod research_memory;` addition.
if echo "$lib_diff" | grep -E '^[+]' | grep -v '^+++' | grep -vE '^\+\s*$' | grep -vE '^\+\s*pub\(crate\) mod research_memory;\s*$'; then
  echo 'lib.rs diff contains lines beyond the research_memory mod line' >&2; exit 1
fi
scan_input=$(printf '%s\n%s\n%s' "$rust_nontest" "$(cat db/migrations/0097_memory_admission.sql)" "$lib_diff")
# A2: exact normalized-line allowlisting for the known-good deny lines.
# Trim leading/trailing whitespace, then exclude only exact full-line matches
# (fixed-string, whole-line). Substring exclusions would allow suffix bypass
# (e.g. `GATE_CHANGE_KEYS_evil` containing the literal as a substring).
# Known-good lines (trimmed):
# - SQL guidance regex line containing the deny alternation (single line with
#   lifecycles?[ _-]states?|...|recipes?|...).
# After B3 the Rust nontest contains no paper_/live_/broker literals (keys come
# from AUTHORITY_KEYS), so only the SQL regex line needs allowlisting; any
# other production line matching paper_|live_|broker fails.
allowlist=$(mktemp)
cat > "$allowlist" <<'ALLOW_EOF'
'\y(authority|lifecycles?[ _-]states?|execution[ _-]environment|execution[ _-]authority|strategy[ _-]eligible|paper[ _-]eligible|trade[ _-]eligible|execution[ _-]edge[ _-]and[ _-]paper[ _-]trading|acceptance[ _-]check|papers?|live|brokers?|recipes?|acceptances?)\y');
ALLOW_EOF
normalized=$(echo "$scan_input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
# Exclude exact allowlisted lines, then scan the remainder.
filtered=$(echo "$normalized" | grep -vFx -f "$allowlist" || true)
rm -f "$allowlist"
if echo "$filtered" | grep -Ei 'paper_|live_|broker'; then
  echo 'execution authority leaked into PR2 production lines' >&2; exit 1
fi
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; fi
}
tested_commit=$(git rev-parse HEAD)
tested_tree=$(git rev-parse 'HEAD^{tree}')
base_merge=$(git merge-base origin/main HEAD)
cat > evidence/research-memory/acceptance.json <<EVIDENCE
{
  "status": "passed",
  "pr": "PR2 memory admission + containment (map #171, decision #173)",
  "tested_commit": "$tested_commit",
  "tested_tree": "$tested_tree",
  "base": "$base_merge",
  "project": "$project",
  "postgres_port": 15443,
  "runtime": "isolated Compose postgres; no credentials or outbound model calls",
  "migrations": "1 through 97 applied to a fresh isolated database using the repository migrator",
  "module_tests": "cargo test --locked research_memory: $module_passed",
  "probe": $probe_line,
  "map_notes": {
    "unsupported_lessons": "missing lineage, non-disjoint support, self-review, and own-lineage support rejected",
    "suspended_expired_memory": "suspended, expired, and contaminated lessons leave future retrieval; superseded resolves to successor",
    "pinned_replay": "exact-version retrieval plus pinned-review flags for already-pinned consumers",
    "dissent_and_duplicates": "dissent preserved versioned; duplicates link to canonical and never count as support",
    "gate_boundary": "recipe, acceptance-check, and authority guidance rejected at admission",
    "cost_controls_unchanged": "no provider cost admission or tier-cost references in PR2 behavior files"
  },
  "sha256": {
    "db/migrations/0097_memory_admission.sql": "$(hash_file db/migrations/0097_memory_admission.sql)",
    "backend/src/research_memory.rs": "$(hash_file backend/src/research_memory.rs)",
    "backend/src/research_contract.rs": "$(hash_file backend/src/research_contract.rs)",
    "backend/src/lib.rs": "$(hash_file backend/src/lib.rs)",
    "db/fixtures/research_memory_probe.sql": "$(hash_file db/fixtures/research_memory_probe.sql)",
    "scripts/research_memory_test.sh": "$(hash_file scripts/research_memory_test.sh)"
  }
}
EVIDENCE
echo 'research-memory acceptance passed; evidence at evidence/research-memory/acceptance.json'
