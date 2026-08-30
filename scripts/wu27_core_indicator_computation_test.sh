#!/usr/bin/env bash
# WU-27 executable acceptance test — Core indicator computation.
# Evidence: indicator replay test report on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-27"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/indicator-replay-report.json"
PROBE_SQL="db/fixtures/wu27_core_indicator_computation_probe.sql"
WU27_PROJECT_NAME="${WU27_COMPOSE_PROJECT_NAME:-market-mate-wu27}"
COMPOSE=(docker compose --project-name "$WU27_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-27 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-27 PASS: $1"; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"; }

wait_for_healthy_services() {
  local attempts="$1" healthy attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    healthy=$("${COMPOSE[@]}" ps --format json 2>/dev/null \
      | jq -r 'select(.Health == "healthy") | .Service' 2>/dev/null \
      | sort -u | tr '\n' ' ')
    if [[ " $healthy " == *" backend "* \
      && " $healthy " == *" frontend "* \
      && " $healthy " == *" postgres "* \
      && " $healthy " == *" custody "* ]]; then return 0; fi
    sleep 2
  done
  return 1
}

append_audit_event() {
  local event_id="$1" event_type="$2" payload="$3"
  "${PSQL[@]}" -c "
    SELECT chain_position FROM append_audit_event(
      \$a\$${event_id}\$a\$, \$a\$${event_type}\$a\$, now(),
      \$a\$${payload}\$a\$::jsonb,
      '{\"source\":\"wu27-acceptance\",\"entitlement_version\":\"indicator-registry-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-27 Core indicator computation test $(date -u +%FT%TZ) (project: $WU27_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28; do
  [[ "$sibling" == "$WU27_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-27 Compose state"
log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 || fail "Compose bring-up failed"
wait_for_healthy_services 300 || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

backend_ready=$(curl -fsS http://127.0.0.1:8080/readyz) || fail "backend /readyz is unavailable"
jq -e '.status == "ok" and .database == true and .migrations == true' <<<"$backend_ready" >/dev/null \
  || fail "backend /readyz is not migration-ready: $backend_ready"
pass "backend readiness confirms migration head"

migration_head=$("${PSQL[@]}" -c "SELECT coalesce(max(version), 0) FROM schema_migration;") \
  || fail "could not read the applied migration head"
[[ "$migration_head" == "28" ]] || fail "expected migration head 28, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 28;") \
  || fail "could not read migration 28 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 28 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 28 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu27-core-indicator-computation-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-27 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu27-core-indicator-computation-probe.sql \
  -c "SELECT result FROM wu27_probe_result;" -c "ROLLBACK;") \
  || fail "WU-27 Core indicator computation probe failed: $probe_result"

for key in \
  t1_current_value t1_binds_definition_version lookahead_replay_unchanged \
  later_as_of_uses_later_bars historical_evaluation_keeps_v1 later_evaluation_binds_v2 \
  incomplete_has_no_value unmapped_is_missing identity_conflict_is_disputed \
  experimental_excluded unknown_formula_blocked noncanonical_horizon_blocked \
  future_as_of_blocked rebind_blocked retired_latest_does_not_fallback \
  direct_insert_blocked \
  observation_update_blocked binding_delete_blocked observation_truncate_blocked \
  appends_audited binding_audited; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "point-in-time Core close-return computation and as-of replay pass"
pass "definition-version binding into evaluations passes"
pass "missing, incomplete, and disputed observations store no numeric substitute"
pass "experimental exclusion, illegal inputs, and append-only probes fail closed"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.indicator_observation', 'INSERT')
     AND NOT has_table_privilege('public', 'public.indicator_evaluation_binding', 'INSERT')
     AND NOT has_function_privilege('public', 'compute_core_indicator_observation(text,uuid,timestamptz,integer,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'bind_core_indicator_into_evaluation(text,uuid,jsonb)', 'EXECUTE');
") || fail "could not inspect public core indicator write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public core indicator write privileges were not revoked"
pass "public core indicator writes are revoked; workflow guards remain the measured local boundary"

replay_payload=$(jq -c '{t1_current_value, t1_binds_definition_version, lookahead_replay_unchanged, later_as_of_uses_later_bars, historical_evaluation_keeps_v1, later_evaluation_binds_v2}' <<<"$probe_result")
gate_payload=$(jq -c '{incomplete_has_no_value, unmapped_is_missing, identity_conflict_is_disputed, experimental_excluded, unknown_formula_blocked, noncanonical_horizon_blocked, future_as_of_blocked, rebind_blocked, retired_latest_does_not_fallback}' <<<"$probe_result")
guard_payload=$(jq -c '{direct_insert_blocked, observation_update_blocked, binding_delete_blocked, observation_truncate_blocked, appends_audited, binding_audited}' <<<"$probe_result")
chain_replay=$(append_audit_event "wu27-replay-$(date +%s)" "research.core_indicator_replay_proved" "$(jq -nc --argjson evidence "$replay_payload" '{probe: "wu27_core_indicator_computation_probe", evidence: $evidence}')") \
  || fail "audit append core_indicator_replay_proved failed"
chain_gate=$(append_audit_event "wu27-gates-$(date +%s)" "research.core_indicator_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu27_core_indicator_computation_probe", evidence: $evidence}')") \
  || fail "audit append core_indicator_gates_proved failed"
chain_guard=$(append_audit_event "wu27-guards-$(date +%s)" "research.core_indicator_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu27_core_indicator_computation_probe", evidence: $evidence}')") \
  || fail "audit append core_indicator_guards_probed failed"
[[ "$chain_gate" -gt "$chain_replay" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_replay -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "replay, gates, and isolated guard probes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson migration_head "$migration_head" \
  --arg migration_checksum "$migration_checksum" \
  --arg migration_schema_head "$migration_schema_head" \
  --arg migration_fingerprint "$migration_fingerprint" \
  --arg public_write_revoked "$public_write_revoked" \
  --argjson audit_position_replay "$chain_replay" \
  --argjson audit_position_gates "$chain_gate" \
  --argjson audit_position_guards "$chain_guard" \
  '{
    captured_at: $captured_at,
    migration: {
      head: $migration_head,
      expected_head: 28,
      version: 28,
      name: "core_indicator_computation",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    replay: {
      t1_current_value: $probe.t1_current_value,
      t1_binds_definition_version: $probe.t1_binds_definition_version,
      lookahead_replay_unchanged: $probe.lookahead_replay_unchanged,
      later_as_of_uses_later_bars: $probe.later_as_of_uses_later_bars,
      historical_evaluation_keeps_v1: $probe.historical_evaluation_keeps_v1,
      later_evaluation_binds_v2: $probe.later_evaluation_binds_v2
    },
    gates: {
      incomplete_has_no_value: $probe.incomplete_has_no_value,
      unmapped_is_missing: $probe.unmapped_is_missing,
      identity_conflict_is_disputed: $probe.identity_conflict_is_disputed,
      experimental_excluded: $probe.experimental_excluded,
      unknown_formula_blocked: $probe.unknown_formula_blocked,
      noncanonical_horizon_blocked: $probe.noncanonical_horizon_blocked,
      future_as_of_blocked: $probe.future_as_of_blocked,
      rebind_blocked: $probe.rebind_blocked,
      retired_latest_does_not_fallback: $probe.retired_latest_does_not_fallback
    },
    append_only_and_fail_closed: {
      direct_insert_blocked: $probe.direct_insert_blocked,
      observation_update_blocked: $probe.observation_update_blocked,
      binding_delete_blocked: $probe.binding_delete_blocked,
      observation_truncate_blocked: $probe.observation_truncate_blocked,
      appends_audited: $probe.appends_audited,
      binding_audited: $probe.binding_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      replay: $audit_position_replay,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-27 evidence report"
jq -e '
  .migration.head == 28
  and .migration.expected_head == 28
  and .migration.name == "core_indicator_computation"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .replay.t1_current_value == true
  and .replay.lookahead_replay_unchanged == true
  and .replay.later_as_of_uses_later_bars == true
  and .replay.historical_evaluation_keeps_v1 == true
  and .replay.later_evaluation_binds_v2 == true
  and .gates.incomplete_has_no_value == true
  and .gates.unmapped_is_missing == true
  and .gates.identity_conflict_is_disputed == true
  and .gates.experimental_excluded == true
  and .gates.rebind_blocked == true
  and .gates.retired_latest_does_not_fallback == true
  and .append_only_and_fail_closed.direct_insert_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.replay
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-27 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-27 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-27 COMPLETE"
