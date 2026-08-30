#!/usr/bin/env bash
# WU-22 executable acceptance test — versioned Coverage Policy machinery.
# Evidence: policy definition, evaluation, and isolated mutation-probe report.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-22"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/coverage-policy-report.json"
PROBE_SQL="db/fixtures/wu22_coverage_policy_probe.sql"
WU22_PROJECT_NAME="${WU22_COMPOSE_PROJECT_NAME:-market-mate-wu22}"
COMPOSE=(docker compose --project-name "$WU22_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-22 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-22 PASS: $1"; }
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
      '$event_id', '$event_type', now(), '$payload'::jsonb,
      '{\"source\":\"wu22-acceptance\",\"entitlement_version\":\"coverage-policy-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq
log "== WU-22 Coverage Policy test $(date -u +%FT%TZ) (project: $WU22_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21; do
  [[ "$sibling" == "$WU22_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-22 Compose state"
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
[[ "$migration_head" == "23" ]] || fail "expected migration head 23, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 23;") \
  || fail "could not read migration 23 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 23 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 23 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu22-coverage-policy-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-22 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu22-coverage-policy-probe.sql \
  -c "SELECT result FROM wu22_probe_result;" -c "ROLLBACK;") \
  || fail "WU-22 Coverage Policy probe failed: $probe_result"

for key in \
  policy_version_valid policy_digest_valid capacity_40_target_50_ceiling \
  capacity_target_freezes_automatic_admission capacity_ceiling_is_recorded \
  stages_and_capabilities_encoded policy_approval_required \
  approval_before_grant_blocked approval_is_time_bound independent_principal_approval_allows_promotion \
  admission_before_target_allowed \
  mandatory_holding_ignores_capacity stage_capacity_limits_enforced options_capability_gate_blocks \
  promotion_gates_fail_closed demotion_blocks_forward_transitions \
  hard_failure_demotes_immediately three_floor_failures_demote \
  candidate_archive_after_60_sessions principal_pin_prevents_archive bottom_fitness_demotes \
  anti_chasing_replacement_gate enhanced_risk_research_gates \
  enhanced_risk_live_limits_encoded enhanced_risk_live_boundaries_fail_closed \
  direct_version_insert_blocked \
  direct_version_update_blocked direct_version_delete_blocked \
  direct_evaluation_truncate_blocked direct_approval_insert_blocked \
  direct_evaluation_insert_blocked policy_self_approval_blocked \
  policy_actor_approval_blocked invalid_definition_append_blocked \
  invalid_version_append_blocked invalid_stage_blocked negative_input_blocked \
  future_as_of_blocked before_effective_blocked wrong_type_input_blocked \
  large_input_blocked workflow_flags_reset; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "policy capacity, stages, capabilities, lifecycle, and promotion gates pass"
pass "demotion, archive, pin, anti-chasing, and enhanced-risk probes pass"
pass "direct policy/evaluation mutation and self-approval probes fail closed"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.coverage_policy_version', 'INSERT')
     AND NOT has_table_privilege('public', 'public.coverage_policy_approval', 'INSERT')
     AND NOT has_table_privilege('public', 'public.coverage_policy_evaluation', 'INSERT')
     AND NOT has_function_privilege('public', 'append_coverage_policy_version(text,integer,jsonb,timestamptz,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'record_coverage_policy_approval(uuid,text,text,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'evaluate_coverage_policy(uuid,text,timestamptz,jsonb,jsonb)', 'EXECUTE');
") || fail "could not inspect public policy write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public policy write privileges were not revoked"
pass "public policy writes are revoked; workflow guards remain the measured local boundary"

policy_payload=$(jq -c '{policy_version_valid, policy_digest_valid, capacity_40_target_50_ceiling, stages_and_capabilities_encoded, policy_approval_required, approval_before_grant_blocked, approval_is_time_bound, independent_principal_approval_allows_promotion}' <<<"$probe_result")
gate_payload=$(jq -c '{admission_before_target_allowed, mandatory_holding_ignores_capacity, stage_capacity_limits_enforced, options_capability_gate_blocks, promotion_gates_fail_closed, demotion_blocks_forward_transitions, hard_failure_demotes_immediately, three_floor_failures_demote, candidate_archive_after_60_sessions, principal_pin_prevents_archive, bottom_fitness_demotes, anti_chasing_replacement_gate, enhanced_risk_research_gates, enhanced_risk_live_limits_encoded, enhanced_risk_live_boundaries_fail_closed}' <<<"$probe_result")
guard_payload=$(jq -c '{direct_version_insert_blocked, direct_version_update_blocked, direct_version_delete_blocked, direct_evaluation_truncate_blocked, direct_approval_insert_blocked, direct_evaluation_insert_blocked, policy_self_approval_blocked, policy_actor_approval_blocked, invalid_definition_append_blocked, invalid_version_append_blocked, invalid_stage_blocked, negative_input_blocked, future_as_of_blocked, before_effective_blocked, wrong_type_input_blocked, large_input_blocked, workflow_flags_reset}' <<<"$probe_result")
chain_policy=$(append_audit_event "wu22-policy-$(date +%s)" "research.coverage_policy_evaluated" "$(jq -nc --argjson evidence "$policy_payload" '{probe: "wu22_coverage_policy_probe", evidence: $evidence}')")
chain_gate=$(append_audit_event "wu22-gates-$(date +%s)" "research.coverage_policy_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu22_coverage_policy_probe", evidence: $evidence}')")
chain_guard=$(append_audit_event "wu22-guards-$(date +%s)" "research.coverage_policy_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu22_coverage_policy_probe", evidence: $evidence}')")
[[ "$chain_gate" -gt "$chain_policy" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_policy -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "policy decisions and isolated guard probes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson migration_head "$migration_head" \
  --arg migration_checksum "$migration_checksum" \
  --arg migration_schema_head "$migration_schema_head" \
  --arg migration_fingerprint "$migration_fingerprint" \
  --arg public_write_revoked "$public_write_revoked" \
  --argjson audit_position_policy "$chain_policy" \
  --argjson audit_position_gates "$chain_gate" \
  --argjson audit_position_guards "$chain_guard" \
  '{
    captured_at: $captured_at,
    migration: {
      head: $migration_head,
      expected_head: 23,
      version: 23,
      name: "coverage_policy",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    policy: {
      version_valid: $probe.policy_version_valid,
      digest_valid: $probe.policy_digest_valid,
      capacity_40_target_50_ceiling: $probe.capacity_40_target_50_ceiling,
      target_freezes_automatic_admission: $probe.capacity_target_freezes_automatic_admission,
      ceiling_recorded: $probe.capacity_ceiling_is_recorded,
      stages_and_capabilities_encoded: $probe.stages_and_capabilities_encoded,
      approval_required: $probe.policy_approval_required,
      approval_before_grant_blocked: $probe.approval_before_grant_blocked,
      approval_is_time_bound: $probe.approval_is_time_bound,
      independent_principal_approval_allows_promotion: $probe.independent_principal_approval_allows_promotion
    },
    gates: {
      admission_before_target_allowed: $probe.admission_before_target_allowed,
      mandatory_holding_ignores_capacity: $probe.mandatory_holding_ignores_capacity,
      stage_capacity_limits_enforced: $probe.stage_capacity_limits_enforced,
      options_capability_gate_blocks: $probe.options_capability_gate_blocks,
      promotion_gates_fail_closed: $probe.promotion_gates_fail_closed,
      demotion_blocks_forward_transitions: $probe.demotion_blocks_forward_transitions,
      hard_failure_demotes_immediately: $probe.hard_failure_demotes_immediately,
      three_floor_failures_demote: $probe.three_floor_failures_demote,
      candidate_archive_after_60_sessions: $probe.candidate_archive_after_60_sessions,
      principal_pin_prevents_archive: $probe.principal_pin_prevents_archive,
      bottom_fitness_demotes: $probe.bottom_fitness_demotes,
      anti_chasing_replacement_gate: $probe.anti_chasing_replacement_gate,
      enhanced_risk_research_gates: $probe.enhanced_risk_research_gates,
      enhanced_risk_live_limits_encoded: $probe.enhanced_risk_live_limits_encoded,
      enhanced_risk_live_boundaries_fail_closed: $probe.enhanced_risk_live_boundaries_fail_closed
    },
    append_only_and_fail_closed: {
      direct_version_insert_blocked: $probe.direct_version_insert_blocked,
      direct_version_update_blocked: $probe.direct_version_update_blocked,
      direct_version_delete_blocked: $probe.direct_version_delete_blocked,
      direct_evaluation_truncate_blocked: $probe.direct_evaluation_truncate_blocked,
      direct_approval_insert_blocked: $probe.direct_approval_insert_blocked,
      direct_evaluation_insert_blocked: $probe.direct_evaluation_insert_blocked,
      policy_self_approval_blocked: $probe.policy_self_approval_blocked,
      policy_actor_approval_blocked: $probe.policy_actor_approval_blocked,
      invalid_definition_append_blocked: $probe.invalid_definition_append_blocked,
      invalid_version_append_blocked: $probe.invalid_version_append_blocked,
      invalid_stage_blocked: $probe.invalid_stage_blocked,
      negative_input_blocked: $probe.negative_input_blocked,
      future_as_of_blocked: $probe.future_as_of_blocked,
      before_effective_blocked: $probe.before_effective_blocked,
      wrong_type_input_blocked: $probe.wrong_type_input_blocked,
      large_input_blocked: $probe.large_input_blocked,
      workflow_flags_reset: $probe.workflow_flags_reset,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {policy: $audit_position_policy, gates: $audit_position_gates, guards: $audit_position_guards}
  }' >"$REPORT" || fail "could not write WU-22 evidence report"
jq -e '
  .migration.head == 23
  and .migration.expected_head == 23
  and .migration.version == 23
  and .migration.name == "coverage_policy"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and (.migration.schema_head | length) > 0
  and (.migration.fingerprint | length) > 0
  and .policy.version_valid == true
  and .policy.digest_valid == true
  and .policy.capacity_40_target_50_ceiling == true
  and .policy.target_freezes_automatic_admission == true
  and .policy.ceiling_recorded == true
  and .policy.stages_and_capabilities_encoded == true
  and .policy.approval_required == true
  and .policy.approval_before_grant_blocked == true
  and .policy.approval_is_time_bound == true
  and .policy.independent_principal_approval_allows_promotion == true
  and .gates.admission_before_target_allowed == true
  and .gates.mandatory_holding_ignores_capacity == true
  and .gates.stage_capacity_limits_enforced == true
  and .gates.options_capability_gate_blocks == true
  and .gates.promotion_gates_fail_closed == true
  and .gates.demotion_blocks_forward_transitions == true
  and .gates.hard_failure_demotes_immediately == true
  and .gates.three_floor_failures_demote == true
  and .gates.candidate_archive_after_60_sessions == true
  and .gates.principal_pin_prevents_archive == true
  and .gates.bottom_fitness_demotes == true
  and .gates.anti_chasing_replacement_gate == true
  and .gates.enhanced_risk_research_gates == true
  and .gates.enhanced_risk_live_limits_encoded == true
  and .gates.enhanced_risk_live_boundaries_fail_closed == true
  and .append_only_and_fail_closed.direct_version_insert_blocked == true
  and .append_only_and_fail_closed.direct_version_update_blocked == true
  and .append_only_and_fail_closed.direct_version_delete_blocked == true
  and .append_only_and_fail_closed.direct_evaluation_truncate_blocked == true
  and .append_only_and_fail_closed.direct_approval_insert_blocked == true
  and .append_only_and_fail_closed.direct_evaluation_insert_blocked == true
  and .append_only_and_fail_closed.policy_self_approval_blocked == true
  and .append_only_and_fail_closed.policy_actor_approval_blocked == true
  and .append_only_and_fail_closed.invalid_definition_append_blocked == true
  and .append_only_and_fail_closed.invalid_version_append_blocked == true
  and .append_only_and_fail_closed.invalid_stage_blocked == true
  and .append_only_and_fail_closed.negative_input_blocked == true
  and .append_only_and_fail_closed.future_as_of_blocked == true
  and .append_only_and_fail_closed.before_effective_blocked == true
  and .append_only_and_fail_closed.wrong_type_input_blocked == true
  and .append_only_and_fail_closed.large_input_blocked == true
  and .append_only_and_fail_closed.workflow_flags_reset == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.policy
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-22 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-22 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-22 COMPLETE"
