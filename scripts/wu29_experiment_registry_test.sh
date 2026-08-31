#!/usr/bin/env bash
# WU-29 executable acceptance test — Experiment Registry preregistration.
# Evidence: registration fixtures + immutability tests on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-29"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/experiment-registry-report.json"
PROBE_SQL="db/fixtures/wu29_experiment_registry_probe.sql"
WU29_PROJECT_NAME="${WU29_COMPOSE_PROJECT_NAME:-market-mate-wu29}"
COMPOSE=(docker compose --project-name "$WU29_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-29 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-29 PASS: $1"; }
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
      '{\"source\":\"wu29-acceptance\",\"entitlement_version\":\"experiment-registry-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-29 Experiment Registry preregistration test $(date -u +%FT%TZ) (project: $WU29_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30; do
  [[ "$sibling" == "$WU29_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-29 Compose state"
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
[[ "$migration_head" == "30" ]] || fail "expected migration head 30, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 30;") \
  || fail "could not read migration 30 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 30 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 30 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu29-experiment-registry-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-29 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu29-experiment-registry-probe.sql \
  -c "SELECT result FROM wu29_probe_result;" -c "ROLLBACK;") \
  || fail "WU-29 Experiment Registry probe failed: $probe_result"

for key in \
  registered_before_result content_addressed spec_fields_recorded \
  idempotent_same_spec direct_insert_blocked spec_update_blocked \
  registration_delete_blocked \
  incomplete_hypothesis_blocked incomplete_windows_blocked \
  incomplete_estimators_blocked incomplete_budget_blocked \
  incomplete_stopping_rule_blocked incomplete_multiplicity_plan_blocked \
  posthoc_without_successor_blocked posthoc_creates_linked_successor \
  original_never_mutates result_stays_on_original tip_is_successor \
  stale_successor_blocked cross_experiment_successor_blocked \
  spec_key_mismatch_blocked alias_fields_accepted \
  registration_truncate_blocked appends_audited; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "preregistration is immutable and content-addressed before any result exists"
pass "post-hoc change appends a linked successor; the original never mutates"
pass "incomplete specs, illegal successors, and append-only probes fail closed"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.experiment_preregistration', 'INSERT')
     AND NOT has_function_privilege('public', 'register_experiment_preregistration(text,jsonb,uuid,jsonb)', 'EXECUTE');
") || fail "could not inspect public experiment preregistration write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public experiment preregistration write privileges were not revoked"
pass "public experiment preregistration writes are revoked; workflow guards remain the measured local boundary"

record_payload=$(jq -c '{registered_before_result, content_addressed, spec_fields_recorded, idempotent_same_spec, posthoc_creates_linked_successor, original_never_mutates, result_stays_on_original, tip_is_successor, alias_fields_accepted}' <<<"$probe_result")
gate_payload=$(jq -c '{incomplete_hypothesis_blocked, incomplete_windows_blocked, incomplete_estimators_blocked, incomplete_budget_blocked, incomplete_stopping_rule_blocked, incomplete_multiplicity_plan_blocked, posthoc_without_successor_blocked, stale_successor_blocked, cross_experiment_successor_blocked, spec_key_mismatch_blocked}' <<<"$probe_result")
guard_payload=$(jq -c '{direct_insert_blocked, spec_update_blocked, registration_delete_blocked, registration_truncate_blocked, appends_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "wu29-record-$(date +%s)" "research.experiment_registry_record_proved" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu29_experiment_registry_probe", evidence: $evidence}')") \
  || fail "audit append experiment_registry_record_proved failed"
chain_gate=$(append_audit_event "wu29-gates-$(date +%s)" "research.experiment_registry_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu29_experiment_registry_probe", evidence: $evidence}')") \
  || fail "audit append experiment_registry_gates_proved failed"
chain_guard=$(append_audit_event "wu29-guards-$(date +%s)" "research.experiment_registry_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu29_experiment_registry_probe", evidence: $evidence}')") \
  || fail "audit append experiment_registry_guards_probed failed"
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
      expected_head: 30,
      version: 30,
      name: "experiment_registry_preregistration",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    registry: {
      registered_before_result: $probe.registered_before_result,
      content_addressed: $probe.content_addressed,
      spec_fields_recorded: $probe.spec_fields_recorded,
      idempotent_same_spec: $probe.idempotent_same_spec,
      posthoc_creates_linked_successor: $probe.posthoc_creates_linked_successor,
      original_never_mutates: $probe.original_never_mutates,
      result_stays_on_original: $probe.result_stays_on_original,
      tip_is_successor: $probe.tip_is_successor,
      alias_fields_accepted: $probe.alias_fields_accepted
    },
    gates: {
      incomplete_hypothesis_blocked: $probe.incomplete_hypothesis_blocked,
      incomplete_windows_blocked: $probe.incomplete_windows_blocked,
      incomplete_estimators_blocked: $probe.incomplete_estimators_blocked,
      incomplete_budget_blocked: $probe.incomplete_budget_blocked,
      incomplete_stopping_rule_blocked: $probe.incomplete_stopping_rule_blocked,
      incomplete_multiplicity_plan_blocked: $probe.incomplete_multiplicity_plan_blocked,
      posthoc_without_successor_blocked: $probe.posthoc_without_successor_blocked,
      stale_successor_blocked: $probe.stale_successor_blocked,
      cross_experiment_successor_blocked: $probe.cross_experiment_successor_blocked,
      spec_key_mismatch_blocked: $probe.spec_key_mismatch_blocked
    },
    append_only_and_fail_closed: {
      direct_insert_blocked: $probe.direct_insert_blocked,
      spec_update_blocked: $probe.spec_update_blocked,
      registration_delete_blocked: $probe.registration_delete_blocked,
      registration_truncate_blocked: $probe.registration_truncate_blocked,
      appends_audited: $probe.appends_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-29 evidence report"
jq -e '
  .migration.head == 30
  and .migration.expected_head == 30
  and .migration.name == "experiment_registry_preregistration"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .registry.registered_before_result == true
  and .registry.content_addressed == true
  and .registry.spec_fields_recorded == true
  and .registry.idempotent_same_spec == true
  and .registry.posthoc_creates_linked_successor == true
  and .registry.original_never_mutates == true
  and .registry.result_stays_on_original == true
  and .gates.incomplete_hypothesis_blocked == true
  and .gates.posthoc_without_successor_blocked == true
  and .append_only_and_fail_closed.direct_insert_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-29 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-29 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-29 COMPLETE"
