#!/usr/bin/env bash
# WU-30 executable acceptance test — Sealed Release Holdout custody.
# Evidence: seal ceremony record on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-30"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/seal-ceremony-record.json"
PROBE_SQL="db/fixtures/wu30_release_holdout_probe.sql"
WU30_PROJECT_NAME="${WU30_COMPOSE_PROJECT_NAME:-market-mate-wu30}"
COMPOSE=(docker compose --project-name "$WU30_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-30 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-30 PASS: $1"; }
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
      '{\"source\":\"wu30-acceptance\",\"entitlement_version\":\"experiment-registry-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-30 Sealed Release Holdout custody test $(date -u +%FT%TZ) (project: $WU30_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30 market-mate-wu31; do
  [[ "$sibling" == "$WU30_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-30 Compose state"
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
[[ "$migration_head" == "31" ]] || fail "expected migration head 31, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 31;") \
  || fail "could not read migration 31 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 31 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 31 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu30-release-holdout-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-30 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu30-release-holdout-probe.sql \
  -c "SELECT result FROM wu30_probe_result;" -c "ROLLBACK;") \
  || fail "WU-30 Release Holdout probe failed: $probe_result"

for key in \
  short_segment_blocked unsorted_segment_blocked future_as_of_blocked \
  last_date_after_as_of_blocked seal_ceremony_recorded idempotent_same_segment \
  unconsumed_second_seal_blocked direct_seal_insert_blocked \
  extra_result_key_blocked extra_key_does_not_consume \
  missing_estimator_key_blocked missing_key_does_not_consume \
  unknown_registration_blocked unsealed_holdout_blocked \
  failed_evaluation_consumes second_evaluation_refused \
  seal_unchanged_after_consumption new_seal_after_consumption \
  seal_update_blocked evaluation_delete_blocked holdout_truncate_blocked \
  seal_audited evaluation_audited; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "holdout seal is a one-time tamper-evident ceremony of at least 60 sessions"
pass "a failed evaluation consumes the holdout; a second evaluation is refused"
pass "illegal segments, extra result keys, and append-only probes fail closed"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.release_holdout_seal', 'INSERT')
     AND NOT has_table_privilege('public', 'public.release_holdout_evaluation', 'INSERT')
     AND NOT has_function_privilege('public', 'seal_release_holdout(date[],timestamptz,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'evaluate_release_holdout(uuid,uuid,jsonb,boolean,jsonb)', 'EXECUTE');
") || fail "could not inspect public release holdout write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public release holdout write privileges were not revoked"
pass "public release holdout writes are revoked; workflow guards remain the measured local boundary"

record_payload=$(jq -c '{seal_ceremony_recorded, idempotent_same_segment, failed_evaluation_consumes, second_evaluation_refused, seal_unchanged_after_consumption, new_seal_after_consumption}' <<<"$probe_result")
gate_payload=$(jq -c '{short_segment_blocked, unsorted_segment_blocked, future_as_of_blocked, last_date_after_as_of_blocked, unconsumed_second_seal_blocked, extra_result_key_blocked, extra_key_does_not_consume, missing_estimator_key_blocked, missing_key_does_not_consume, unknown_registration_blocked, unsealed_holdout_blocked}' <<<"$probe_result")
guard_payload=$(jq -c '{direct_seal_insert_blocked, seal_update_blocked, evaluation_delete_blocked, holdout_truncate_blocked, seal_audited, evaluation_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "wu30-record-$(date +%s)" "research.release_holdout_record_proved" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu30_release_holdout_probe", evidence: $evidence}')") \
  || fail "audit append release_holdout_record_proved failed"
chain_gate=$(append_audit_event "wu30-gates-$(date +%s)" "research.release_holdout_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu30_release_holdout_probe", evidence: $evidence}')") \
  || fail "audit append release_holdout_gates_proved failed"
chain_guard=$(append_audit_event "wu30-guards-$(date +%s)" "research.release_holdout_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu30_release_holdout_probe", evidence: $evidence}')") \
  || fail "audit append release_holdout_guards_probed failed"
[[ "$chain_gate" -gt "$chain_record" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "seal ceremony, gates, and isolated guard probes are recorded on the verified audit chain"

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
      expected_head: 31,
      version: 31,
      name: "release_holdout_custody",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    ceremony: {
      seal_ceremony_recorded: $probe.seal_ceremony_recorded,
      idempotent_same_segment: $probe.idempotent_same_segment,
      failed_evaluation_consumes: $probe.failed_evaluation_consumes,
      second_evaluation_refused: $probe.second_evaluation_refused,
      seal_unchanged_after_consumption: $probe.seal_unchanged_after_consumption,
      new_seal_after_consumption: $probe.new_seal_after_consumption
    },
    gates: {
      short_segment_blocked: $probe.short_segment_blocked,
      unsorted_segment_blocked: $probe.unsorted_segment_blocked,
      future_as_of_blocked: $probe.future_as_of_blocked,
      last_date_after_as_of_blocked: $probe.last_date_after_as_of_blocked,
      unconsumed_second_seal_blocked: $probe.unconsumed_second_seal_blocked,
      extra_result_key_blocked: $probe.extra_result_key_blocked,
      extra_key_does_not_consume: $probe.extra_key_does_not_consume,
      missing_estimator_key_blocked: $probe.missing_estimator_key_blocked,
      missing_key_does_not_consume: $probe.missing_key_does_not_consume,
      unknown_registration_blocked: $probe.unknown_registration_blocked,
      unsealed_holdout_blocked: $probe.unsealed_holdout_blocked
    },
    append_only_and_fail_closed: {
      direct_seal_insert_blocked: $probe.direct_seal_insert_blocked,
      seal_update_blocked: $probe.seal_update_blocked,
      evaluation_delete_blocked: $probe.evaluation_delete_blocked,
      holdout_truncate_blocked: $probe.holdout_truncate_blocked,
      seal_audited: $probe.seal_audited,
      evaluation_audited: $probe.evaluation_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-30 evidence report"
jq -e '
  .migration.head == 31
  and .migration.expected_head == 31
  and .migration.name == "release_holdout_custody"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .ceremony.seal_ceremony_recorded == true
  and .ceremony.failed_evaluation_consumes == true
  and .ceremony.second_evaluation_refused == true
  and .gates.short_segment_blocked == true
  and .gates.unconsumed_second_seal_blocked == true
  and .gates.missing_estimator_key_blocked == true
  and .gates.missing_key_does_not_consume == true
  and .append_only_and_fail_closed.direct_seal_insert_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-30 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-30 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-30 COMPLETE"
