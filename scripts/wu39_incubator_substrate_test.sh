#!/usr/bin/env bash
# WU-39 executable acceptance test — Incubator substrate.
# Evidence: Alpha Shot lineage records on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-39"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/alpha-shot-lineage.json"
PROBE_SQL="db/fixtures/wu39_incubator_substrate_probe.sql"
WU39_PROJECT_NAME="${WU39_COMPOSE_PROJECT_NAME:-market-mate-wu39}"
COMPOSE=(docker compose --project-name "$WU39_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-39 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-39 PASS: $1"; }
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
      '{\"source\":\"wu39-acceptance\",\"entitlement_version\":\"incubator-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-39 Incubator substrate test $(date -u +%FT%TZ) (project: $WU39_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30 market-mate-wu31 market-mate-wu32 market-mate-wu33 market-mate-wu34 market-mate-wu35 market-mate-wu36 market-mate-wu37 market-mate-wu38 market-mate-wu39 market-mate-wu40 market-mate-harden-wu28-31; do
  [[ "$sibling" == "$WU39_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-39 Compose state"
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
[[ "$migration_head" == "41" ]] || fail "expected migration head 41, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 41;") \
  || fail "could not read migration 41 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 41 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 41 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu39-incubator-substrate-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-39 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu39-incubator-substrate-probe.sql \
  -c "SELECT result FROM wu39_probe_result;" -c "ROLLBACK;") \
  || fail "WU-39 Incubator substrate probe failed: $probe_result"

for key in \
  alpha_shot_recorded failure_lineage single_research_lane record_is_idempotent \
  sentinel_allows_entitled_use sentinel_denies_non_entitled_use \
  manager_assignment_rejected risk_assignment_rejected compliance_assignment_rejected \
  paper_lane_rejected null_outcome_blocked empty_stopping_rule_blocked spec_mismatch_blocked \
  direct_insert_blocked shot_update_blocked shot_delete_blocked \
  shot_truncate_blocked shot_audited no_authority_grant; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "Alpha Shots record hypothesis, budget, stopping rule, result, and failure lineage"
pass "Engine-lite stays in the research lane; charter rejects manager/risk/compliance"
pass "Sentinel denies non-entitled evidence use"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.alpha_shot', 'INSERT')
     AND NOT has_table_privilege('public', 'public.incubator_assignment', 'INSERT')
     AND NOT has_function_privilege('public', 'record_alpha_shot(jsonb,jsonb,uuid,text,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'engine_admit_research_assignment(jsonb,jsonb)', 'EXECUTE');
") || fail "could not inspect public incubator write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public incubator write privileges were not revoked"
pass "public incubator writes are revoked; workflow guards remain the measured local boundary"

record_payload=$(jq -c '{alpha_shot_recorded, failure_lineage, single_research_lane, record_is_idempotent, no_authority_grant}' <<<"$probe_result")
gate_payload=$(jq -c '{sentinel_allows_entitled_use, sentinel_denies_non_entitled_use, manager_assignment_rejected, risk_assignment_rejected, compliance_assignment_rejected, paper_lane_rejected, null_outcome_blocked, empty_stopping_rule_blocked, spec_mismatch_blocked}' <<<"$probe_result")
guard_payload=$(jq -c '{direct_insert_blocked, shot_update_blocked, shot_delete_blocked, shot_truncate_blocked, shot_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "wu39-record-$(date +%s)" "research.alpha_shot_lineage_proved" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu39_incubator_substrate_probe", evidence: $evidence}')") \
  || fail "audit append alpha_shot_lineage_proved failed"
chain_gate=$(append_audit_event "wu39-gates-$(date +%s)" "research.incubator_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu39_incubator_substrate_probe", evidence: $evidence}')") \
  || fail "audit append incubator_gates_proved failed"
chain_guard=$(append_audit_event "wu39-guards-$(date +%s)" "research.incubator_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu39_incubator_substrate_probe", evidence: $evidence}')") \
  || fail "audit append incubator_guards_probed failed"
[[ "$chain_gate" -gt "$chain_record" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "Alpha Shot lineage, gates, and isolated guard probes are recorded on the verified audit chain"

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
      expected_head: 41,
      version: 41,
      name: "incubator_substrate",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    lineage: {
      alpha_shot_recorded: $probe.alpha_shot_recorded,
      failure_lineage: $probe.failure_lineage,
      single_research_lane: $probe.single_research_lane,
      record_is_idempotent: $probe.record_is_idempotent,
      no_authority_grant: $probe.no_authority_grant
    },
    gates: {
      sentinel_allows_entitled_use: $probe.sentinel_allows_entitled_use,
      sentinel_denies_non_entitled_use: $probe.sentinel_denies_non_entitled_use,
      manager_assignment_rejected: $probe.manager_assignment_rejected,
      risk_assignment_rejected: $probe.risk_assignment_rejected,
      compliance_assignment_rejected: $probe.compliance_assignment_rejected,
      paper_lane_rejected: $probe.paper_lane_rejected,
      null_outcome_blocked: $probe.null_outcome_blocked,
      empty_stopping_rule_blocked: $probe.empty_stopping_rule_blocked,
      spec_mismatch_blocked: $probe.spec_mismatch_blocked
    },
    append_only_and_fail_closed: {
      direct_insert_blocked: $probe.direct_insert_blocked,
      shot_update_blocked: $probe.shot_update_blocked,
      shot_delete_blocked: $probe.shot_delete_blocked,
      shot_truncate_blocked: $probe.shot_truncate_blocked,
      shot_audited: $probe.shot_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-39 evidence report"
jq -e '
  .migration.head == 41
  and .migration.expected_head == 41
  and .migration.name == "incubator_substrate"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .lineage.alpha_shot_recorded == true
  and .lineage.failure_lineage == true
  and .gates.sentinel_denies_non_entitled_use == true
  and .gates.manager_assignment_rejected == true
  and .gates.null_outcome_blocked == true
  and .gates.spec_mismatch_blocked == true
  and .append_only_and_fail_closed.direct_insert_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-39 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-39 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-39 COMPLETE"
