#!/usr/bin/env bash
# WU-34 executable acceptance test — Walk-forward engine.
# Evidence: walk-forward run manifests on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-34"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/walk-forward-run-manifest.json"
PROBE_SQL="db/fixtures/wu34_walk_forward_probe.sql"
WU34_PROJECT_NAME="${WU34_COMPOSE_PROJECT_NAME:-market-mate-wu34}"
COMPOSE=(docker compose --project-name "$WU34_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-34 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-34 PASS: $1"; }
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
      '{\"source\":\"wu34-acceptance\",\"entitlement_version\":\"walk-forward-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-34 Walk-forward engine test $(date -u +%FT%TZ) (project: $WU34_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30 market-mate-wu31 market-mate-wu32 market-mate-wu33 market-mate-wu34 market-mate-wu35 market-mate-harden-wu28-31; do
  [[ "$sibling" == "$WU34_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-34 Compose state"
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
[[ "$migration_head" == "36" ]] || fail "expected migration head 36, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 36;") \
  || fail "could not read migration 36 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 36 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 36 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu34-walk-forward-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-34 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu34-walk-forward-probe.sql \
  -c "SELECT result FROM wu34_probe_result;" -c "ROLLBACK;") \
  || fail "WU-34 Walk-forward probe failed: $probe_result"

for key in \
  calendar_registered three_windows_recorded each_test_ge_250 \
  disjoint_tests purge_gap_present no_train_test_overlap no_purge_leakage \
  holdout_excluded slice_excludes_train_and_purge double_run_digest_match \
  record_is_idempotent fixture_evaluation_deterministic \
  sandbox_session_cap_still_enforced sixty_one_session_snapshot_blocked \
  credential_source_payload_blocked extra_source_key_blocked \
  source_bar_out_of_scope_blocked sessions_object_blocked \
  short_window_blocked two_windows_blocked overlapping_windows_blocked \
  train_test_overlap_blocked purge_leakage_blocked holdout_overlap_blocked \
  placement_frozen_after_results direct_insert_blocked run_update_blocked \
  run_delete_blocked run_truncate_blocked calendar_truncate_blocked \
  run_audited; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "preregistered walk-forward windows are disjoint, >=250 days, and purged"
pass "window placement cannot change after a run manifest exists"
pass "WU-33 60-session sandbox cap remains fail-closed"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.walk_forward_run', 'INSERT')
     AND NOT has_table_privilege('public', 'public.walk_forward_calendar', 'INSERT')
     AND NOT has_function_privilege('public', 'record_walk_forward_run(uuid,uuid,uuid,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'register_walk_forward_calendar(date[],jsonb)', 'EXECUTE');
") || fail "could not inspect public walk-forward write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public walk-forward write privileges were not revoked"
pass "public walk-forward writes are revoked; workflow guards remain the measured local boundary"

record_payload=$(jq -c '{three_windows_recorded, each_test_ge_250, disjoint_tests, record_is_idempotent, fixture_evaluation_deterministic}' <<<"$probe_result")
gate_payload=$(jq -c '{short_window_blocked, two_windows_blocked, overlapping_windows_blocked, train_test_overlap_blocked, purge_leakage_blocked, holdout_overlap_blocked, sandbox_session_cap_still_enforced, credential_source_payload_blocked, extra_source_key_blocked, source_bar_out_of_scope_blocked, sessions_object_blocked}' <<<"$probe_result")
guard_payload=$(jq -c '{placement_frozen_after_results, direct_insert_blocked, run_update_blocked, run_delete_blocked, run_truncate_blocked, calendar_truncate_blocked, run_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "wu34-record-$(date +%s)" "research.walk_forward_manifest_proved" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu34_walk_forward_probe", evidence: $evidence}')") \
  || fail "audit append walk_forward_manifest_proved failed"
chain_gate=$(append_audit_event "wu34-gates-$(date +%s)" "research.walk_forward_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu34_walk_forward_probe", evidence: $evidence}')") \
  || fail "audit append walk_forward_gates_proved failed"
chain_guard=$(append_audit_event "wu34-guards-$(date +%s)" "research.walk_forward_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu34_walk_forward_probe", evidence: $evidence}')") \
  || fail "audit append walk_forward_guards_probed failed"
[[ "$chain_gate" -gt "$chain_record" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "walk-forward manifests, gates, and isolated guard probes are recorded on the verified audit chain"

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
      expected_head: 36,
      version: 36,
      name: "walk_forward_engine",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    manifest: {
      three_windows_recorded: $probe.three_windows_recorded,
      each_test_ge_250: $probe.each_test_ge_250,
      disjoint_tests: $probe.disjoint_tests,
      purge_gap_present: $probe.purge_gap_present,
      no_train_test_overlap: $probe.no_train_test_overlap,
      no_purge_leakage: $probe.no_purge_leakage,
      holdout_excluded: $probe.holdout_excluded,
      record_is_idempotent: $probe.record_is_idempotent,
      fixture_evaluation_deterministic: $probe.fixture_evaluation_deterministic
    },
    gates: {
      short_window_blocked: $probe.short_window_blocked,
      two_windows_blocked: $probe.two_windows_blocked,
      overlapping_windows_blocked: $probe.overlapping_windows_blocked,
      train_test_overlap_blocked: $probe.train_test_overlap_blocked,
      purge_leakage_blocked: $probe.purge_leakage_blocked,
      holdout_overlap_blocked: $probe.holdout_overlap_blocked,
      sandbox_session_cap_still_enforced: $probe.sandbox_session_cap_still_enforced,
      sixty_one_session_snapshot_blocked: $probe.sixty_one_session_snapshot_blocked,
      credential_source_payload_blocked: $probe.credential_source_payload_blocked,
      extra_source_key_blocked: $probe.extra_source_key_blocked,
      source_bar_out_of_scope_blocked: $probe.source_bar_out_of_scope_blocked,
      sessions_object_blocked: $probe.sessions_object_blocked
    },
    append_only_and_fail_closed: {
      placement_frozen_after_results: $probe.placement_frozen_after_results,
      direct_insert_blocked: $probe.direct_insert_blocked,
      run_update_blocked: $probe.run_update_blocked,
      run_delete_blocked: $probe.run_delete_blocked,
      run_truncate_blocked: $probe.run_truncate_blocked,
      calendar_truncate_blocked: $probe.calendar_truncate_blocked,
      run_audited: $probe.run_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-34 evidence report"
jq -e '
  .migration.head == 36
  and .migration.expected_head == 36
  and .migration.name == "walk_forward_engine"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .manifest.three_windows_recorded == true
  and .manifest.each_test_ge_250 == true
  and .manifest.disjoint_tests == true
  and .manifest.purge_gap_present == true
  and .manifest.no_train_test_overlap == true
  and .manifest.no_purge_leakage == true
  and .manifest.record_is_idempotent == true
  and .gates.short_window_blocked == true
  and .gates.sandbox_session_cap_still_enforced == true
  and .gates.credential_source_payload_blocked == true
  and .gates.extra_source_key_blocked == true
  and .gates.source_bar_out_of_scope_blocked == true
  and .gates.sessions_object_blocked == true
  and .append_only_and_fail_closed.placement_frozen_after_results == true
  and .append_only_and_fail_closed.direct_insert_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-34 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-34 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-34 COMPLETE"
