#!/usr/bin/env bash
# WU-03 executable acceptance test — append-only audit-event hash chain.
# Evidence: chain verification report written to evidence/wu-03/.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-03"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/chain-verification-report.json"
WU03_PROJECT_NAME="${WU03_COMPOSE_PROJECT_NAME:-market-mate-wu03}"
COMPOSE=(docker compose --project-name "$WU03_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() {
  printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"
}

fail() {
  log "WU-03 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}

pass() {
  log "WU-03 PASS: $1"
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
      && " $healthy " == *" postgres "* ]]; then
      return 0
    fi
    sleep 2
  done

  return 1
}

append_event() {
  local event_id="$1"
  local event_type="$2"
  local event_time="$3"
  local payload="$4"
  local receipt_time="$5"

  "${PSQL[@]}" -qAtc "
    SELECT row_to_json(event_row)
    FROM append_audit_event(
      '$event_id',
      '$event_type',
      '$event_time'::timestamptz,
      '$payload'::jsonb,
      '{\"source\":\"wu03-acceptance\",\"entitlement_version\":\"local-v1\"}'::jsonb,
      '$receipt_time'::timestamptz,
      'local_research'
    ) AS event_row;
  "
}

require_command curl
require_command docker
require_command jq

log "== WU-03 audit-chain test $(date -u +%FT%TZ) (project: $WU03_PROJECT_NAME) =="

"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose configuration is invalid"

docker compose --project-name market-mate-wu01 down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
docker compose --project-name market-mate-wu02 down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove prior WU-03 Compose state"

log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose bring-up failed"

wait_for_healthy_services 120 \
  || fail "backend, frontend, and postgres did not all reach healthy"
pass "full Compose stack is healthy"

backend_ready=$(curl -fsS http://127.0.0.1:8080/readyz) \
  || fail "backend /readyz is unavailable"
jq -e '.status == "ok" and .database == true and .migrations == true' \
  <<<"$backend_ready" >/dev/null \
  || fail "backend /readyz is not migration-ready: $backend_ready"

audit_registration=$("${PSQL[@]}" -qAtc "
  SELECT json_build_object(
    'head_version', (SELECT max(version) FROM schema_migration),
    'registered_kind', (SELECT kind FROM schema_object WHERE table_name = 'audit_event'),
    'pgcrypto_installed', EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto')
  );
") || fail "audit-event schema is unavailable"
jq -e '.head_version >= 3 and .registered_kind == "evidence" and .pgcrypto_installed == true' \
  <<<"$audit_registration" >/dev/null \
  || fail "audit-event schema is not registered at migration head: $audit_registration"
pass "audit_event is a registered evidence table with cryptographic hashing available"

# The backend may already have emitted chain events at startup (restore
# verification); the WU-03 events append after the current head.
head_before=$("${PSQL[@]}" -qAtc \
  "SELECT coalesce(max(chain_position), 0) FROM audit_event;") \
  || fail "could not read the current chain head"

event_one=$(append_event \
  "wu03-0001" \
  "wu03.verification_started" \
  "2026-08-28T20:00:00Z" \
  '{"action":"start","unit":"WU-03"}' \
  "2026-08-28T20:00:01Z") \
  || fail "first canonical event append failed"
event_two=$(append_event \
  "wu03-0002" \
  "wu03.immutability_probed" \
  "2026-08-28T20:00:02Z" \
  '{"action":"probe","unit":"WU-03"}' \
  "2026-08-28T20:00:03Z") \
  || fail "second canonical event append failed"
event_three=$(append_event \
  "wu03-0003" \
  "wu03.verification_completed" \
  "2026-08-28T20:00:04Z" \
  '{"action":"complete","unit":"WU-03"}' \
  "2026-08-28T20:00:05Z") \
  || fail "third canonical event append failed"

events=$(jq -n \
  --argjson first "$event_one" \
  --argjson second "$event_two" \
  --argjson third "$event_three" \
  --argjson head_before "$head_before" \
  '[$first, $second, $third]')
jq -e --argjson head_before "$head_before" '
  [.[].chain_position] == [$head_before + 1, $head_before + 2, $head_before + 3]
  and all(.[]; (.event_hash | length) == 64 and (.previous_hash | length) == 64)
  and .[1].previous_hash == .[0].event_hash
  and .[2].previous_hash == .[1].event_hash
' <<<"$events" >/dev/null \
  || fail "appended events do not form a predecessor-linked chain: $events"
pass "canonical events link to their predecessor hashes"

expected_total=$((head_before + 3))
valid_verification=$("${PSQL[@]}" -qAtc \
  "SELECT row_to_json(result) FROM verify_audit_event_chain() AS result;") \
  || fail "valid chain verification failed to run"
jq -e ".valid == true and .checked_events == $expected_total and .break_position == null and .reason == null" \
  <<<"$valid_verification" >/dev/null \
  || fail "valid chain did not verify: $valid_verification"
pass "untampered chain verifies"

tamper_target=$((head_before + 2))
set +e
update_output=$("${PSQL[@]}" -qAtc \
  "UPDATE audit_event SET payload = jsonb_set(payload, '{forbidden}', 'true') WHERE chain_position = $tamper_target;" 2>&1)
update_status=$?
delete_output=$("${PSQL[@]}" -qAtc \
  "DELETE FROM audit_event WHERE chain_position = $tamper_target;" 2>&1)
delete_status=$?
direct_insert_output=$("${PSQL[@]}" -qAtc "
  INSERT INTO audit_event (
    chain_position, event_id, event_type, event_time, payload,
    source_lineage, receipt_time, record_environment, previous_hash, event_hash
  ) VALUES (
    $((expected_total + 1)), 'forged', 'forged', '2026-08-28T20:00:06Z', '{}'::jsonb,
    '{\"source\":\"forged\",\"entitlement_version\":\"v1\"}'::jsonb,
    '2026-08-28T20:00:07Z', 'local_research', repeat('0', 64), repeat('0', 64)
  );
" 2>&1)
direct_insert_status=$?
set -e

[[ "$update_status" -ne 0 && "$delete_status" -ne 0 && "$direct_insert_status" -ne 0 ]] \
  || fail "append-only guards allowed mutation or forged insertion"
grep -qi 'append-only' <<<"$update_output" \
  || fail "update denial did not explain the append-only boundary: $update_output"
grep -qi 'append-only' <<<"$delete_output" \
  || fail "delete denial did not explain the append-only boundary: $delete_output"
grep -qi 'append_audit_event' <<<"$direct_insert_output" \
  || fail "direct insert denial did not name the canonical append interface: $direct_insert_output"
pass "updates, deletes, and direct inserts fail closed"

tampered_verification=$("${PSQL[@]}" -qAtc "
  BEGIN;
  SET LOCAL session_replication_role = replica;
  UPDATE audit_event
     SET payload = jsonb_set(payload, '{action}', '\"tampered\"'::jsonb)
   WHERE chain_position = $tamper_target;
  SET LOCAL session_replication_role = origin;
  SELECT row_to_json(result) FROM verify_audit_event_chain() AS result;
  ROLLBACK;
") || fail "tamper-detection probe failed to run"
jq -e --argjson tamper_target "$tamper_target" '
  .valid == false
  and .checked_events == ($tamper_target - 1)
  and .break_position == $tamper_target
  and .reason == "event_hash_mismatch"
  and .expected_event_hash != .actual_event_hash
' <<<"$tampered_verification" >/dev/null \
  || fail "tampered byte did not identify the exact break point: $tampered_verification"
pass "tampering is reported at exact chain position $tamper_target"

final_verification=$("${PSQL[@]}" -qAtc \
  "SELECT row_to_json(result) FROM verify_audit_event_chain() AS result;") \
  || fail "final chain verification failed to run"
jq -e ".valid == true and .checked_events == $expected_total" <<<"$final_verification" >/dev/null \
  || fail "tamper probe did not roll back cleanly: $final_verification"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson backend_ready "$backend_ready" \
  --argjson schema "$audit_registration" \
  --argjson events "$events" \
  --argjson valid_verification "$valid_verification" \
  --argjson tampered_verification "$tampered_verification" \
  --argjson final_verification "$final_verification" \
  --arg update_output "$update_output" \
  --arg delete_output "$delete_output" \
  --arg direct_insert_output "$direct_insert_output" \
  '{
    captured_at: $captured_at,
    backend_ready: $backend_ready,
    schema: $schema,
    events: $events,
    valid_verification: $valid_verification,
    tamper_probe: $tampered_verification,
    mutation_guards: {
      update_failed_closed: true,
      update_output: $update_output,
      delete_failed_closed: true,
      delete_output: $delete_output,
      direct_insert_failed_closed: true,
      direct_insert_output: $direct_insert_output
    },
    final_verification: $final_verification
  }' >"$REPORT" \
  || fail "could not write chain verification report"

jq -e '
  .backend_ready.status == "ok"
  and .schema.registered_kind == "evidence"
  and (.events | length) == 3
  and .valid_verification.valid == true
  and .tamper_probe.valid == false
  and .tamper_probe.break_position == (.events[1].chain_position)
  and .mutation_guards.update_failed_closed == true
  and .mutation_guards.delete_failed_closed == true
  and .mutation_guards.direct_insert_failed_closed == true
  and .final_verification.valid == true
' "$REPORT" >/dev/null \
  || fail "chain verification report does not satisfy the WU-03 evidence schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] \
  || fail "named WU-03 evidence is not retrievable"

pass "valid evidence is retrievable at $REPORT"
log "WU-03 COMPLETE"
