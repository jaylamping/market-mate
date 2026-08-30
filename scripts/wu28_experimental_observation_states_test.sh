#!/usr/bin/env bash
# WU-28 executable acceptance test — Experimental observation states.
# Evidence: experimental-indicator record on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-28"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/experimental-indicator-record.json"
PROBE_SQL="db/fixtures/wu28_experimental_observation_states_probe.sql"
WU28_PROJECT_NAME="${WU28_COMPOSE_PROJECT_NAME:-market-mate-wu28}"
COMPOSE=(docker compose --project-name "$WU28_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-28 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-28 PASS: $1"; }
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
      '{\"source\":\"wu28-acceptance\",\"entitlement_version\":\"indicator-registry-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-28 Experimental observation states test $(date -u +%FT%TZ) (project: $WU28_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29; do
  [[ "$sibling" == "$WU28_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-28 Compose state"
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
[[ "$migration_head" == "29" ]] || fail "expected migration head 29, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 29;") \
  || fail "could not read migration 29 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 29 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 29 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu28-experimental-observation-states-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-28 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu28-experimental-observation-states-probe.sql \
  -c "SELECT result FROM wu28_probe_result;" -c "ROLLBACK;") \
  || fail "WU-28 Experimental observation states probe failed: $probe_result"

for key in \
  recorded_as_experimental experimental_excluded_from_core \
  unknown_preregistration_blocked incomplete_preregistration_blocked \
  incomplete_horizon_blocked incomplete_universe_blocked \
  incomplete_stopping_rule_blocked incomplete_promotion_gate_blocked \
  incomplete_testing_budget_blocked \
  mismatched_preregistration_indicator_blocked lineage_missing_predecessor_blocked \
  lineage_digest_mismatch_blocked core_cannot_enter_experimental_stages \
  retired_experimental_register_blocked advance_without_preregistration_blocked \
  registered_with_preregistration_and_lineage duplicate_registration_blocked \
  preregistration_cannot_bind_second_definition stage_skip_blocked \
  stage_reverse_blocked experimental_never_becomes_core \
  foreign_preregistration_advance_blocked stale_predecessor_blocked \
  full_stage_path_recorded strategy_eligible_stays_experimental \
  strategy_eligible_still_excluded_from_core \
  direct_lineage_insert_blocked direct_stage_insert_blocked \
  stage_update_blocked lineage_delete_blocked stage_truncate_blocked \
  appends_audited advances_audited; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "experimental indicator is recorded as experimental and excluded from Core"
pass "promotion requires a complete #42 preregistration and full lineage"
pass "evidence stages advance only consecutively and never become Core"
pass "append-only and isolated fail-closed probes pass"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.experimental_indicator_lineage', 'INSERT')
     AND NOT has_table_privilege('public', 'public.experimental_indicator_stage', 'INSERT')
     AND NOT has_function_privilege('public', 'register_experimental_indicator_use(uuid,uuid,jsonb,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'advance_experimental_indicator_stage(uuid,text,jsonb,jsonb)', 'EXECUTE');
") || fail "could not inspect public experimental indicator write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public experimental indicator write privileges were not revoked"
pass "public experimental indicator writes are revoked; workflow guards remain the measured local boundary"

record_payload=$(jq -c '{recorded_as_experimental, experimental_excluded_from_core, registered_with_preregistration_and_lineage, full_stage_path_recorded, strategy_eligible_stays_experimental, strategy_eligible_still_excluded_from_core}' <<<"$probe_result")
gate_payload=$(jq -c '{unknown_preregistration_blocked, incomplete_preregistration_blocked, incomplete_horizon_blocked, incomplete_universe_blocked, incomplete_stopping_rule_blocked, incomplete_promotion_gate_blocked, incomplete_testing_budget_blocked, mismatched_preregistration_indicator_blocked, lineage_missing_predecessor_blocked, lineage_digest_mismatch_blocked, core_cannot_enter_experimental_stages, retired_experimental_register_blocked, advance_without_preregistration_blocked, duplicate_registration_blocked, preregistration_cannot_bind_second_definition, stage_skip_blocked, stage_reverse_blocked, experimental_never_becomes_core, foreign_preregistration_advance_blocked, stale_predecessor_blocked}' <<<"$probe_result")
guard_payload=$(jq -c '{direct_lineage_insert_blocked, direct_stage_insert_blocked, stage_update_blocked, lineage_delete_blocked, stage_truncate_blocked, appends_audited, advances_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "wu28-record-$(date +%s)" "research.experimental_indicator_record_proved" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu28_experimental_observation_states_probe", evidence: $evidence}')") \
  || fail "audit append experimental_indicator_record_proved failed"
chain_gate=$(append_audit_event "wu28-gates-$(date +%s)" "research.experimental_indicator_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu28_experimental_observation_states_probe", evidence: $evidence}')") \
  || fail "audit append experimental_indicator_gates_proved failed"
chain_guard=$(append_audit_event "wu28-guards-$(date +%s)" "research.experimental_indicator_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu28_experimental_observation_states_probe", evidence: $evidence}')") \
  || fail "audit append experimental_indicator_guards_probed failed"
[[ "$chain_gate" -gt "$chain_record" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "record, gates, and isolated guard probes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson migration_head "$migration_head" \
  --arg migration_checksum "$migration_checksum" \
  --arg migration_schema_head "$migration_schema_head" \
  --arg migration_fingerprint "$migration_fingerprint" \
  --arg public_write_revoked "$public_write_revoked" \
  --argjson audit_position_record "$chain_record" \
  --argjson audit_position_gates "$chain_gate" \
  --argjson audit_position_guards "$chain_guard" \
  '{
    captured_at: $captured_at,
    migration: {
      head: $migration_head,
      expected_head: 29,
      version: 29,
      name: "experimental_observation_states",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    record: {
      recorded_as_experimental: $probe.recorded_as_experimental,
      experimental_excluded_from_core: $probe.experimental_excluded_from_core,
      registered_with_preregistration_and_lineage: $probe.registered_with_preregistration_and_lineage,
      full_stage_path_recorded: $probe.full_stage_path_recorded,
      strategy_eligible_stays_experimental: $probe.strategy_eligible_stays_experimental,
      strategy_eligible_still_excluded_from_core: $probe.strategy_eligible_still_excluded_from_core
    },
    gates: {
      unknown_preregistration_blocked: $probe.unknown_preregistration_blocked,
      incomplete_preregistration_blocked: $probe.incomplete_preregistration_blocked,
      incomplete_horizon_blocked: $probe.incomplete_horizon_blocked,
      incomplete_universe_blocked: $probe.incomplete_universe_blocked,
      incomplete_stopping_rule_blocked: $probe.incomplete_stopping_rule_blocked,
      incomplete_promotion_gate_blocked: $probe.incomplete_promotion_gate_blocked,
      incomplete_testing_budget_blocked: $probe.incomplete_testing_budget_blocked,
      mismatched_preregistration_indicator_blocked: $probe.mismatched_preregistration_indicator_blocked,
      lineage_missing_predecessor_blocked: $probe.lineage_missing_predecessor_blocked,
      lineage_digest_mismatch_blocked: $probe.lineage_digest_mismatch_blocked,
      core_cannot_enter_experimental_stages: $probe.core_cannot_enter_experimental_stages,
      retired_experimental_register_blocked: $probe.retired_experimental_register_blocked,
      advance_without_preregistration_blocked: $probe.advance_without_preregistration_blocked,
      duplicate_registration_blocked: $probe.duplicate_registration_blocked,
      preregistration_cannot_bind_second_definition: $probe.preregistration_cannot_bind_second_definition,
      stage_skip_blocked: $probe.stage_skip_blocked,
      stage_reverse_blocked: $probe.stage_reverse_blocked,
      experimental_never_becomes_core: $probe.experimental_never_becomes_core,
      foreign_preregistration_advance_blocked: $probe.foreign_preregistration_advance_blocked,
      stale_predecessor_blocked: $probe.stale_predecessor_blocked
    },
    append_only_and_fail_closed: {
      direct_lineage_insert_blocked: $probe.direct_lineage_insert_blocked,
      direct_stage_insert_blocked: $probe.direct_stage_insert_blocked,
      stage_update_blocked: $probe.stage_update_blocked,
      lineage_delete_blocked: $probe.lineage_delete_blocked,
      stage_truncate_blocked: $probe.stage_truncate_blocked,
      appends_audited: $probe.appends_audited,
      advances_audited: $probe.advances_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-28 evidence report"
jq -e '
  .migration.head == 29
  and .migration.expected_head == 29
  and .migration.name == "experimental_observation_states"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .record.recorded_as_experimental == true
  and .record.experimental_excluded_from_core == true
  and .record.registered_with_preregistration_and_lineage == true
  and .record.full_stage_path_recorded == true
  and .record.strategy_eligible_stays_experimental == true
  and .record.strategy_eligible_still_excluded_from_core == true
  and .gates.unknown_preregistration_blocked == true
  and .gates.incomplete_preregistration_blocked == true
  and .gates.incomplete_horizon_blocked == true
  and .gates.incomplete_universe_blocked == true
  and .gates.incomplete_stopping_rule_blocked == true
  and .gates.incomplete_promotion_gate_blocked == true
  and .gates.incomplete_testing_budget_blocked == true
  and .gates.advance_without_preregistration_blocked == true
  and .gates.experimental_never_becomes_core == true
  and .gates.stage_skip_blocked == true
  and .gates.stage_reverse_blocked == true
  and .append_only_and_fail_closed.direct_lineage_insert_blocked == true
  and .append_only_and_fail_closed.stage_truncate_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-28 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-28 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-28 COMPLETE"
