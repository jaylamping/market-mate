#!/usr/bin/env bash
# WU-33 executable acceptance test — Deterministic evaluation sandbox.
# Evidence: determinism verification (double-run digest match) on the audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-33"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/determinism-verification.json"
PROBE_SQL="db/fixtures/wu33_strategy_sandbox_probe.sql"
WU33_PROJECT_NAME="${WU33_COMPOSE_PROJECT_NAME:-market-mate-wu33}"
COMPOSE=(docker compose --project-name "$WU33_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-33 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-33 PASS: $1"; }
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
      '{\"source\":\"wu33-acceptance\",\"entitlement_version\":\"strategy-sandbox-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-33 Deterministic evaluation sandbox test $(date -u +%FT%TZ) (project: $WU33_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30 market-mate-wu31 market-mate-wu32 market-mate-wu33 market-mate-wu34 market-mate-harden-wu28-31; do
  [[ "$sibling" == "$WU33_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-33 Compose state"
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
[[ "$migration_head" == "35" ]] || fail "expected migration head 35, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 35;") \
  || fail "could not read migration 35 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 35 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 35 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu33-strategy-sandbox-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-33 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu33-strategy-sandbox-probe.sql \
  -c "SELECT result FROM wu33_probe_result;" -c "ROLLBACK;") \
  || fail "WU-33 Strategy sandbox probe failed: $probe_result"

for key in \
  double_run_digest_match fixture_evaluation_deterministic \
  prose_rules_blocked out_of_scope_signal_blocked credential_payload_blocked \
  network_payload_blocked sp500_bar_out_of_scope_blocked \
  extra_snapshot_key_blocked resource_bound_blocked \
  recorded_evaluation record_is_idempotent prose_strategy_record_blocked \
  unknown_strategy_blocked unknown_snapshot_blocked direct_insert_blocked \
  evaluation_update_blocked evaluation_delete_blocked evaluation_truncate_blocked \
  evaluation_audited; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "same Strategy Version and snapshot produce a byte-identical evaluation digest"
pass "prose rules, out-of-scope signals, credential/network payloads, and oversized snapshots fail closed"
pass "recorded sandbox evaluations are append-only and idempotent"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.strategy_sandbox_evaluation', 'INSERT')
     AND NOT has_function_privilege('public', 'record_strategy_sandbox_evaluation(uuid,uuid,jsonb)', 'EXECUTE');
") || fail "could not inspect public strategy sandbox write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public strategy sandbox write privileges were not revoked"
pass "public strategy sandbox writes are revoked; workflow guards remain the measured local boundary"

record_payload=$(jq -c '{double_run_digest_match, fixture_evaluation_deterministic, recorded_evaluation, record_is_idempotent}' <<<"$probe_result")
gate_payload=$(jq -c '{prose_rules_blocked, out_of_scope_signal_blocked, credential_payload_blocked, network_payload_blocked, sp500_bar_out_of_scope_blocked, extra_snapshot_key_blocked, resource_bound_blocked, prose_strategy_record_blocked, unknown_strategy_blocked, unknown_snapshot_blocked}' <<<"$probe_result")
guard_payload=$(jq -c '{direct_insert_blocked, evaluation_update_blocked, evaluation_delete_blocked, evaluation_truncate_blocked, evaluation_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "wu33-record-$(date +%s)" "research.strategy_sandbox_record_proved" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu33_strategy_sandbox_probe", evidence: $evidence}')") \
  || fail "audit append strategy_sandbox_record_proved failed"
chain_gate=$(append_audit_event "wu33-gates-$(date +%s)" "research.strategy_sandbox_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu33_strategy_sandbox_probe", evidence: $evidence}')") \
  || fail "audit append strategy_sandbox_gates_proved failed"
chain_guard=$(append_audit_event "wu33-guards-$(date +%s)" "research.strategy_sandbox_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu33_strategy_sandbox_probe", evidence: $evidence}')") \
  || fail "audit append strategy_sandbox_guards_probed failed"
[[ "$chain_gate" -gt "$chain_record" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "determinism, gates, and isolated guard probes are recorded on the verified audit chain"

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
      expected_head: 35,
      version: 35,
      name: "strategy_sandbox_evaluation",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    determinism: {
      double_run_digest_match: $probe.double_run_digest_match,
      fixture_evaluation_deterministic: $probe.fixture_evaluation_deterministic,
      recorded_evaluation: $probe.recorded_evaluation,
      record_is_idempotent: $probe.record_is_idempotent
    },
    gates: {
      prose_rules_blocked: $probe.prose_rules_blocked,
      out_of_scope_signal_blocked: $probe.out_of_scope_signal_blocked,
      credential_payload_blocked: $probe.credential_payload_blocked,
      network_payload_blocked: $probe.network_payload_blocked,
      sp500_bar_out_of_scope_blocked: $probe.sp500_bar_out_of_scope_blocked,
      extra_snapshot_key_blocked: $probe.extra_snapshot_key_blocked,
      resource_bound_blocked: $probe.resource_bound_blocked,
      prose_strategy_record_blocked: $probe.prose_strategy_record_blocked,
      unknown_strategy_blocked: $probe.unknown_strategy_blocked,
      unknown_snapshot_blocked: $probe.unknown_snapshot_blocked
    },
    append_only_and_fail_closed: {
      direct_insert_blocked: $probe.direct_insert_blocked,
      evaluation_update_blocked: $probe.evaluation_update_blocked,
      evaluation_delete_blocked: $probe.evaluation_delete_blocked,
      evaluation_truncate_blocked: $probe.evaluation_truncate_blocked,
      evaluation_audited: $probe.evaluation_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-33 evidence report"
jq -e '
  .migration.head == 35
  and .migration.expected_head == 35
  and .migration.name == "strategy_sandbox_evaluation"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .determinism.double_run_digest_match == true
  and .determinism.fixture_evaluation_deterministic == true
  and .determinism.record_is_idempotent == true
  and .gates.prose_rules_blocked == true
  and .gates.network_payload_blocked == true
  and .gates.sp500_bar_out_of_scope_blocked == true
  and .gates.credential_payload_blocked == true
  and .append_only_and_fail_closed.direct_insert_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-33 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-33 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-33 COMPLETE"
