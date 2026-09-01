#!/usr/bin/env bash
# WU-40 executable acceptance test — Capital Feasibility Assessor core.
# Evidence: feasibility computation traces on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-40"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/feasibility-computation-trace.json"
PROBE_SQL="db/fixtures/wu40_capital_feasibility_probe.sql"
WU40_PROJECT_NAME="${WU40_COMPOSE_PROJECT_NAME:-market-mate-wu40}"
COMPOSE=(docker compose --project-name "$WU40_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-40 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-40 PASS: $1"; }
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
      '{\"source\":\"wu40-acceptance\",\"entitlement_version\":\"feasibility-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-40 Capital Feasibility Assessor test $(date -u +%FT%TZ) (project: $WU40_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30 market-mate-wu31 market-mate-wu32 market-mate-wu33 market-mate-wu34 market-mate-wu35 market-mate-wu36 market-mate-wu37 market-mate-wu38 market-mate-wu39 market-mate-wu40 market-mate-wu41 market-mate-harden-wu28-31; do
  [[ "$sibling" == "$WU40_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-40 Compose state"
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
[[ "$migration_head" == "44" ]] || fail "expected migration head 44, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 44;") \
  || fail "could not read migration 44 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 44 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 44 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu40-capital-feasibility-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-40 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu40-capital-feasibility-probe.sql \
  -c "SELECT result FROM wu40_probe_result;" -c "ROLLBACK;") \
  || fail "WU-40 Capital Feasibility Assessor probe failed: $probe_result"

for key in \
  min_units_computed collateral_computed fees_computed approvals_recorded \
  fits_bankroll expensive_does_not_fit record_is_idempotent long_and_credit_assessed \
  missing_fee_schedule_blocked missing_chain_snapshot_blocked uncertified_mapping_blocked \
  naked_short_blocked missing_quotes_blocked fractional_multiplier_blocked \
  direct_insert_blocked assessment_update_blocked assessment_delete_blocked \
  assessment_truncate_blocked assessment_audited no_authority_grant; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "assessor computes min units, collateral, approvals, and fees on the \$1,000 bankroll"
pass "missing fee schedule, chain snapshot, or certified mapping fail closed"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.capital_feasibility_assessment', 'INSERT')
     AND NOT has_table_privilege('public', 'public.capital_feasibility_fee_schedule', 'INSERT')
     AND NOT has_function_privilege('public', 'record_capital_feasibility_assessment(jsonb,jsonb,uuid,uuid,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'register_capital_feasibility_fee_schedule(jsonb,jsonb)', 'EXECUTE');
") || fail "could not inspect public feasibility write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public feasibility write privileges were not revoked"
pass "public feasibility writes are revoked; workflow guards remain the measured local boundary"

record_payload=$(jq -c '{min_units_computed, collateral_computed, fees_computed, approvals_recorded, fits_bankroll, expensive_does_not_fit, record_is_idempotent, no_authority_grant}' <<<"$probe_result")
gate_payload=$(jq -c '{missing_fee_schedule_blocked, missing_chain_snapshot_blocked, uncertified_mapping_blocked, naked_short_blocked, missing_quotes_blocked, fractional_multiplier_blocked, long_and_credit_assessed}' <<<"$probe_result")
guard_payload=$(jq -c '{direct_insert_blocked, assessment_update_blocked, assessment_delete_blocked, assessment_truncate_blocked, assessment_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "wu40-record-$(date +%s)" "research.capital_feasibility_traced" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu40_capital_feasibility_probe", evidence: $evidence}')") \
  || fail "audit append capital_feasibility_traced failed"
chain_gate=$(append_audit_event "wu40-gates-$(date +%s)" "research.capital_feasibility_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu40_capital_feasibility_probe", evidence: $evidence}')") \
  || fail "audit append capital_feasibility_gates_proved failed"
chain_guard=$(append_audit_event "wu40-guards-$(date +%s)" "research.capital_feasibility_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu40_capital_feasibility_probe", evidence: $evidence}')") \
  || fail "audit append capital_feasibility_guards_probed failed"
[[ "$chain_gate" -gt "$chain_record" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "feasibility traces, gates, and isolated guard probes are recorded on the verified audit chain"

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
      expected_head: 44,
      version: 44,
      name: "capital_feasibility_assessor",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    computation: {
      min_units_computed: $probe.min_units_computed,
      collateral_computed: $probe.collateral_computed,
      fees_computed: $probe.fees_computed,
      approvals_recorded: $probe.approvals_recorded,
      fits_bankroll: $probe.fits_bankroll,
      expensive_does_not_fit: $probe.expensive_does_not_fit,
      record_is_idempotent: $probe.record_is_idempotent,
      no_authority_grant: $probe.no_authority_grant
    },
    fail_closed: {
      missing_fee_schedule_blocked: $probe.missing_fee_schedule_blocked,
      missing_chain_snapshot_blocked: $probe.missing_chain_snapshot_blocked,
      uncertified_mapping_blocked: $probe.uncertified_mapping_blocked,
      naked_short_blocked: $probe.naked_short_blocked,
      missing_quotes_blocked: $probe.missing_quotes_blocked,
      fractional_multiplier_blocked: $probe.fractional_multiplier_blocked
    },
    append_only_and_fail_closed: {
      direct_insert_blocked: $probe.direct_insert_blocked,
      assessment_update_blocked: $probe.assessment_update_blocked,
      assessment_delete_blocked: $probe.assessment_delete_blocked,
      assessment_truncate_blocked: $probe.assessment_truncate_blocked,
      assessment_audited: $probe.assessment_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-40 evidence report"
jq -e '
  .migration.head == 44
  and .migration.expected_head == 44
  and .migration.name == "capital_feasibility_assessor"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .computation.min_units_computed == true
  and .computation.collateral_computed == true
  and .computation.fees_computed == true
  and .computation.fits_bankroll == true
  and .fail_closed.missing_fee_schedule_blocked == true
  and .fail_closed.missing_chain_snapshot_blocked == true
  and .fail_closed.uncertified_mapping_blocked == true
  and .fail_closed.fractional_multiplier_blocked == true
  and .append_only_and_fail_closed.direct_insert_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-40 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-40 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-40 COMPLETE"
