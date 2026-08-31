#!/usr/bin/env bash
# WU-38 executable acceptance test — Qualification report artifact.
# Evidence: the qualification report artifact on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-38"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/qualification-report-artifact.json"
PROBE_SQL="db/fixtures/wu38_qualification_report_probe.sql"
WU38_PROJECT_NAME="${WU38_COMPOSE_PROJECT_NAME:-market-mate-wu38}"
COMPOSE=(docker compose --project-name "$WU38_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-38 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-38 PASS: $1"; }
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
      '{\"source\":\"wu38-acceptance\",\"entitlement_version\":\"qualification-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-38 Qualification report artifact test $(date -u +%FT%TZ) (project: $WU38_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30 market-mate-wu31 market-mate-wu32 market-mate-wu33 market-mate-wu34 market-mate-wu35 market-mate-wu36 market-mate-wu37 market-mate-wu38 market-mate-wu39 market-mate-harden-wu28-31; do
  [[ "$sibling" == "$WU38_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-38 Compose state"
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
[[ "$migration_head" == "40" ]] || fail "expected migration head 40, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 40;") \
  || fail "could not read migration 40 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 40 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 40 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu38-qualification-report-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-38 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu38-qualification-report-probe.sql \
  -c "SELECT result FROM wu38_probe_result;" -c "ROLLBACK;") \
  || fail "WU-38 qualification report probe failed: $probe_result"

for key in \
  failed_evaluation_complete passed_evaluation_complete equal_completeness \
  deterministic_replay record_is_idempotent does_not_grant_authority \
  report_frozen_after_results hard_sp500_required direct_insert_blocked \
  report_update_blocked report_delete_blocked report_truncate_blocked \
  report_audited; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "completed and failed evaluations share the same report keys"
pass "deterministic replay matches; the report does not grant authority"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.research_qualification_report', 'INSERT')
     AND NOT has_function_privilege(
       'public',
       'record_research_qualification_report(uuid,uuid,uuid,uuid,uuid,uuid,uuid,uuid,jsonb)',
       'EXECUTE');
") || fail "could not inspect public qualification-report write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public qualification-report write privileges were not revoked"
pass "public qualification-report writes are revoked; workflow guards remain the measured local boundary"

record_payload=$(jq -c '{failed_evaluation_complete, passed_evaluation_complete, equal_completeness, deterministic_replay, record_is_idempotent, does_not_grant_authority}' <<<"$probe_result")
gate_payload=$(jq -c '{hard_sp500_required, report_frozen_after_results}' <<<"$probe_result")
guard_payload=$(jq -c '{direct_insert_blocked, report_update_blocked, report_delete_blocked, report_truncate_blocked, report_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "wu38-record-$(date +%s)" "research.qualification_artifact_proved" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu38_qualification_report_probe", evidence: $evidence}')") \
  || fail "audit append qualification_artifact_proved failed"
chain_gate=$(append_audit_event "wu38-gates-$(date +%s)" "research.qualification_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu38_qualification_report_probe", evidence: $evidence}')") \
  || fail "audit append qualification_gates_proved failed"
chain_guard=$(append_audit_event "wu38-guards-$(date +%s)" "research.qualification_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu38_qualification_report_probe", evidence: $evidence}')") \
  || fail "audit append qualification_guards_probed failed"
[[ "$chain_gate" -gt "$chain_record" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "qualification artifacts, gates, and isolated guard probes are recorded on the verified audit chain"

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
      expected_head: 40,
      version: 40,
      name: "qualification_report",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    artifact: {
      failed_evaluation_complete: $probe.failed_evaluation_complete,
      passed_evaluation_complete: $probe.passed_evaluation_complete,
      equal_completeness: $probe.equal_completeness,
      deterministic_replay: $probe.deterministic_replay,
      record_is_idempotent: $probe.record_is_idempotent,
      does_not_grant_authority: $probe.does_not_grant_authority
    },
    gates: {
      hard_sp500_required: $probe.hard_sp500_required,
      report_frozen_after_results: $probe.report_frozen_after_results
    },
    append_only_and_fail_closed: {
      direct_insert_blocked: $probe.direct_insert_blocked,
      report_update_blocked: $probe.report_update_blocked,
      report_delete_blocked: $probe.report_delete_blocked,
      report_truncate_blocked: $probe.report_truncate_blocked,
      report_audited: $probe.report_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-38 evidence report"
jq -e '
  .migration.head == 40
  and .migration.expected_head == 40
  and .migration.name == "qualification_report"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .artifact.failed_evaluation_complete == true
  and .artifact.passed_evaluation_complete == true
  and .artifact.equal_completeness == true
  and .artifact.deterministic_replay == true
  and .artifact.does_not_grant_authority == true
  and .append_only_and_fail_closed.direct_insert_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-38 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-38 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-38 COMPLETE"
