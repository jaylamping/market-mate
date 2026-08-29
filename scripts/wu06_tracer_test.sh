#!/usr/bin/env bash
# WU-06 executable acceptance test — end-to-end tracer slice.
# Evidence: tracer run artifact written to evidence/wu-06/.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-06"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/tracer-run-report.json"
WU06_PROJECT_NAME="${WU06_COMPOSE_PROJECT_NAME:-market-mate-wu06}"
COMPOSE=(docker compose --project-name "$WU06_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -U mm -d market_mate)
BACKEND_URL="${WU06_BACKEND_URL:-http://127.0.0.1:8080}"

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() {
  printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"
}

fail() {
  log "WU-06 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}

pass() {
  log "WU-06 PASS: $1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

wait_for_healthy_services() {
  local attempts="$1"
  local healthy
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    healthy=$("${COMPOSE[@]}" ps --format json 2>/dev/null \
      | jq -r 'select(.Health == "healthy") | .Service' 2>/dev/null \
      | sort -u \
      | tr '\n' ' ')
    if [[ " $healthy " == *" backend "* \
      && " $healthy " == *" frontend "* \
      && " $healthy " == *" postgres "* \
      && " $healthy " == *" custody "* ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

require_command curl
require_command docker
require_command jq
require_command shasum

log "== WU-06 tracer test $(date -u +%FT%TZ) (project: $WU06_PROJECT_NAME) =="

"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose configuration is invalid"

for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06; do
  if [[ "$sibling" == "$WU06_PROJECT_NAME" ]]; then continue; fi
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove prior WU-06 Compose state"

log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose bring-up failed"

wait_for_healthy_services 300 \
  || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

# 1. Two tracer runs, each producing snapshot + preregistration + evaluation + chain positions.
run_one=$(curl -fsS -X POST "$BACKEND_URL/tracer/run") \
  || fail "first tracer run failed"
run_two=$(curl -fsS -X POST "$BACKEND_URL/tracer/run") \
  || fail "second tracer run failed"

for run in "$run_one" "$run_two"; do
  jq -e '
    (.symbols | length) == 5
    and (.snapshot_id | length) == 36
    and (.snapshot_digest | test("^[0-9a-f]{64}$"))
    and (.preregistration_id | length) == 36
    and (.spec_digest | test("^[0-9a-f]{64}$"))
    and (.evaluation_id | length) == 36
    and (.result_digest | test("^[0-9a-f]{64}$"))
    and .audit_positions.snapshot_captured > 0
    and .audit_positions.preregistration_created > .audit_positions.snapshot_captured
    and .audit_positions.evaluation_recorded > .audit_positions.preregistration_created
  ' <<<"$run" >/dev/null \
    || fail "tracer run artifact is not well-formed: $run"
done
pass "two tracer runs each produced snapshot, preregistration, evaluation, and chain positions"

# 2. Determinism: identical inputs produce byte-identical artifacts.
[[ "$(jq -r '.snapshot_digest' <<<"$run_one")" == "$(jq -r '.snapshot_digest' <<<"$run_two")" ]] \
  || fail "snapshot payload digest diverged between identical runs"
[[ "$(jq -r '.spec_digest' <<<"$run_one")" == "$(jq -r '.spec_digest' <<<"$run_two")" ]] \
  || fail "preregistration digest diverged between runs"
[[ "$(jq -r '.result_digest' <<<"$run_one")" == "$(jq -r '.result_digest' <<<"$run_two")" ]] \
  || fail "evaluation result digest diverged between runs"
pass "double-run digest match: snapshot, preregistration, and evaluation are deterministic"

# 3. Snapshot store holds the run with verifiable digest and lineage.
snapshot_ok=$("${PSQL[@]}" -qAtc "
  SELECT row_to_json(r) FROM (
    SELECT count(*) AS snapshots,
           bool_and(payload_digest = encode(digest(payload::text, 'sha256'), 'hex')) AS digests_verify,
           bool_and(source_lineage->>'source' = 'inline-tracer') AS lineage_present
    FROM research_snapshot WHERE snapshot_kind = 'tracer_inline'
  ) r;
") || fail "snapshot store verification query failed"
jq -e '.snapshots == 2 and .digests_verify == true and .lineage_present == true' \
  <<<"$snapshot_ok" >/dev/null \
  || fail "snapshot store digests or lineage failed verification: $snapshot_ok"
pass "snapshot store holds both runs; every payload digest verifies against its payload"

# 4. Preregistration is content-addressed and precedes its recorded result.
prereg_ok=$("${PSQL[@]}" -qAtc "
  SELECT bool_and(
    spec_digest = encode(digest('market-mate-preregistration-v1' || chr(124) || spec::text, 'sha256'), 'hex')
  ) FROM experiment_preregistration WHERE experiment_key = 'wu06-tracer-toy';
") || fail "preregistration digest verification query failed"
[[ "$prereg_ok" == "t" ]] \
  || fail "preregistration spec digests do not verify: $prereg_ok"

ordering_ok=$("${PSQL[@]}" -qAtc "
  SELECT bool_and(p.receipt_time <= e.receipt_time)
  FROM evaluation_result e
  JOIN experiment_preregistration p ON p.registration_id = e.registration_id;
") || fail "preregistration/evaluation ordering query failed"
[[ "$ordering_ok" == "t" ]] \
  || fail "an evaluation result was recorded before its preregistration"
pass "preregistrations are content-addressed and precede every recorded result"

# 5. Fail-closed probes: the tracer contracts are append-only and FK-protected.
if "${PSQL[@]}" -q -c "UPDATE research_snapshot SET payload = '{\"tampered\":true}'::jsonb;" >/dev/null 2>&1; then
  fail "research_snapshot accepted an UPDATE; append-only contract is broken"
fi
if "${PSQL[@]}" -q -c "DELETE FROM experiment_preregistration;" >/dev/null 2>&1; then
  fail "experiment_preregistration accepted a DELETE; append-only contract is broken"
fi
random_registration=$("${PSQL[@]}" -qAtc "SELECT gen_random_uuid()::text;")
if "${PSQL[@]}" -q -c "INSERT INTO evaluation_result (registration_id, snapshot_id, result, result_digest, source_lineage, receipt_time, record_environment) VALUES ('$random_registration', gen_random_uuid(), '{}', '$(printf 'a%.0s' {1..64})', '{\"source\":\"probe\",\"entitlement_version\":\"local-v1\"}', now(), 'local_research');" >/dev/null 2>&1; then
  fail "evaluation_result accepted an orphan registration; referential gate is broken"
fi
pass "snapshot, preregistration, and evaluation contracts reject mutation and orphans"

# 6. The run appears on the append-only audit chain with full lineage.
chain_ok=$("${PSQL[@]}" -qAtc "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification query failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null \
  || fail "audit chain does not verify: $chain_ok"

for position in \
  "$(jq -r '.audit_positions.snapshot_captured' <<<"$run_one")" \
  "$(jq -r '.audit_positions.preregistration_created' <<<"$run_one")" \
  "$(jq -r '.audit_positions.evaluation_recorded' <<<"$run_one")"; do
  event_row=$("${PSQL[@]}" -qAtc "
    SELECT event_type || '|' || (payload->>'snapshot_id' IS NOT NULL)
    FROM audit_event WHERE chain_position = $position;
  ") || fail "audit event at position $position is missing"
  grep -q '^tracer\.' <<<"$event_row" \
    || fail "audit event at position $position is not a tracer event: $event_row"
done
pass "tracer run is bound into the append-only audit chain at the reported positions"

# 7. Assemble and validate the evidence report.
jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson run_one "$run_one" \
  --argjson run_two "$run_two" \
  --argjson snapshot_store "$snapshot_ok" \
  --argjson chain "$chain_ok" \
  --arg preregistration_ordering_ok "$ordering_ok" \
  '{
    captured_at: $captured_at,
    runs: {
      first: $run_one,
      second: $run_two
    },
    determinism: {
      snapshot_digest_match: ($run_one.snapshot_digest == $run_two.snapshot_digest),
      spec_digest_match: ($run_one.spec_digest == $run_two.spec_digest),
      result_digest_match: ($run_one.result_digest == $run_two.result_digest)
    },
    snapshot_store: $snapshot_store,
    preregistration_precedes_result: ($preregistration_ordering_ok == "t"),
    immutability_probes: {
      snapshot_update_blocked: true,
      preregistration_delete_blocked: true,
      orphan_result_blocked: true
    },
    audit_chain: $chain
  }' >"$REPORT" \
  || fail "could not write tracer run report"

jq -e '
  (.runs.first.symbols | length) == 5
  and .determinism.snapshot_digest_match
  and .determinism.spec_digest_match
  and .determinism.result_digest_match
  and .snapshot_store.snapshots == 2
  and .snapshot_store.digests_verify == true
  and .snapshot_store.lineage_present == true
  and .preregistration_precedes_result == true
  and .immutability_probes.snapshot_update_blocked == true
  and .immutability_probes.preregistration_delete_blocked == true
  and .immutability_probes.orphan_result_blocked == true
  and .audit_chain.valid == true
  and .runs.first.audit_positions.evaluation_recorded > 0
  and .runs.first.result.difference_bps != null
' "$REPORT" >/dev/null \
  || fail "tracer run report does not satisfy the WU-06 evidence schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] \
  || fail "named WU-06 evidence is not retrievable"

pass "valid evidence is retrievable at $REPORT"
log "WU-06 COMPLETE"
