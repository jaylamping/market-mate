#!/usr/bin/env bash
# WU-44 executable acceptance test — Operating Cost model projections.
# Evidence: the stage-1 cost model artifact on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-44"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/stage-1-cost-model.json"
PROBE_SQL="db/fixtures/wu44_cost_model_probe.sql"
WU44_PROJECT_NAME="${WU44_COMPOSE_PROJECT_NAME:-market-mate-wu44}"
COMPOSE=(docker compose --project-name "$WU44_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-44 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-44 PASS: $1"; }
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
      '{\"source\":\"wu44-acceptance\",\"entitlement_version\":\"cost-model-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-44 Operating Cost model test $(date -u +%FT%TZ) (project: $WU44_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30 market-mate-wu31 market-mate-wu32 market-mate-wu33 market-mate-wu34 market-mate-wu35 market-mate-wu36 market-mate-wu37 market-mate-wu38 market-mate-wu39 market-mate-wu40 market-mate-wu41 market-mate-wu42 market-mate-wu43 market-mate-wu44 market-mate-wu45 market-mate-harden-wu28-31; do
  [[ "$sibling" == "$WU44_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-44 Compose state"
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
[[ "$migration_head" == "48" ]] || fail "expected migration head 48, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 48;") \
  || fail "could not read migration 48 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 48 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 48 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu44-cost-model-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-44 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu44-cost-model-probe.sql \
  -c "SELECT result FROM wu44_probe_result;" -c "ROLLBACK;") \
  || fail "WU-44 Operating Cost model probe failed: $probe_result"

for key in \
  stage1_within_caps escalation_flagged record_is_idempotent \
  unnamed_over_cap_blocked over_cap_names_decision \
  missing_quote_input_blocked missing_envelope_blocked spec_mismatch_blocked \
  direct_insert_blocked model_update_blocked model_delete_blocked \
  model_truncate_blocked model_audited no_authority_grant; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "stage-1 vendor set stays within #41 caps; over-cap models name the required decision"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.operating_cost_model', 'INSERT')
     AND NOT has_function_privilege('public', 'record_operating_cost_model(text,jsonb,jsonb,jsonb)', 'EXECUTE');
") || fail "could not inspect public cost-model write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public cost-model write privileges were not revoked"
pass "public cost-model writes are revoked; workflow guards remain the measured local boundary"

record_payload=$(jq -c '{stage1_within_caps, escalation_flagged, record_is_idempotent, no_authority_grant}' <<<"$probe_result")
gate_payload=$(jq -c '{unnamed_over_cap_blocked, over_cap_names_decision, missing_quote_input_blocked, missing_envelope_blocked, spec_mismatch_blocked}' <<<"$probe_result")
guard_payload=$(jq -c '{direct_insert_blocked, model_update_blocked, model_delete_blocked, model_truncate_blocked, model_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "wu44-record-$(date +%s)" "research.operating_cost_model_traced" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu44_cost_model_probe", evidence: $evidence}')") \
  || fail "audit append operating_cost_model_traced failed"
chain_gate=$(append_audit_event "wu44-gates-$(date +%s)" "research.operating_cost_model_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu44_cost_model_probe", evidence: $evidence}')") \
  || fail "audit append operating_cost_model_gates_proved failed"
chain_guard=$(append_audit_event "wu44-guards-$(date +%s)" "research.operating_cost_model_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu44_cost_model_probe", evidence: $evidence}')") \
  || fail "audit append operating_cost_model_guards_probed failed"
[[ "$chain_gate" -gt "$chain_record" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "cost model artifact, gates, and isolated guard probes are recorded on the verified audit chain"

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
      expected_head: 48,
      version: 48,
      name: "operating_cost_model",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    model: {
      stage1_within_caps: $probe.stage1_within_caps,
      escalation_flagged: $probe.escalation_flagged,
      record_is_idempotent: $probe.record_is_idempotent,
      no_authority_grant: $probe.no_authority_grant
    },
    gates: {
      unnamed_over_cap_blocked: $probe.unnamed_over_cap_blocked,
      over_cap_names_decision: $probe.over_cap_names_decision,
      missing_quote_input_blocked: $probe.missing_quote_input_blocked,
      missing_envelope_blocked: $probe.missing_envelope_blocked,
      spec_mismatch_blocked: $probe.spec_mismatch_blocked
    },
    append_only_and_fail_closed: {
      direct_insert_blocked: $probe.direct_insert_blocked,
      model_update_blocked: $probe.model_update_blocked,
      model_delete_blocked: $probe.model_delete_blocked,
      model_truncate_blocked: $probe.model_truncate_blocked,
      model_audited: $probe.model_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-44 evidence report"
jq -e '
  .migration.head == 48
  and .migration.expected_head == 48
  and .migration.name == "operating_cost_model"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .model.stage1_within_caps == true
  and .model.escalation_flagged == true
  and .gates.unnamed_over_cap_blocked == true
  and .gates.over_cap_names_decision == true
  and .append_only_and_fail_closed.direct_insert_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-44 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-44 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-44 COMPLETE"
