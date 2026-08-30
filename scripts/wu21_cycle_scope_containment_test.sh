#!/usr/bin/env bash
# WU-21 executable acceptance test — stale and degraded cycle containment.
# Evidence: containment drill results for complete, degraded, incomplete,
# failed, and stale intervals with typed downstream consumers.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-21"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/cycle-scope-containment-report.json"
PROBE_SQL="db/fixtures/wu21_cycle_scope_containment_probe.sql"
WU21_PROJECT_NAME="${WU21_COMPOSE_PROJECT_NAME:-market-mate-wu21}"
COMPOSE=(docker compose --project-name "$WU21_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-21 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-21 PASS: $1"; }
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
      '{\"source\":\"wu21-acceptance\",\"entitlement_version\":\"cycle-containment-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq
log "== WU-21 cycle scope containment test $(date -u +%FT%TZ) (project: $WU21_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20; do
  [[ "$sibling" == "$WU21_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-21 Compose state"
log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 || fail "Compose bring-up failed"
wait_for_healthy_services 300 || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"
migration_head=$("${PSQL[@]}" -c "SELECT coalesce(max(version), 0) FROM schema_migration;") \
  || fail "could not read the applied migration head"
[[ "$migration_head" == "22" ]] || fail "expected migration head 22, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 22;") \
  || fail "could not read migration 22 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 22 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'research_cycle_consumer_contract', 'INSERT')
     AND NOT has_table_privilege('public', 'research_cycle_scope_effect', 'INSERT')
     AND NOT has_table_privilege('public', 'research_cycle_scope_decision', 'INSERT')
     AND NOT has_function_privilege('public', 'register_research_cycle_consumer(text,text,text,text,jsonb,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'record_research_cycle_scope_effect(uuid,text,text,text,text,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'assess_research_cycle_consumer(uuid,text,timestamptz,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'require_research_cycle_consumer_access(uuid,text,timestamptz,jsonb)', 'EXECUTE');
") || fail "could not read WU-21 public privileges"
[[ "$public_write_revoked" == "t" ]] || fail "WU-21 public write privileges are not revoked"
pass "migration head 22 and schema identity are applied"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu21-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-21 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu21-probe.sql \
  -c "SELECT result FROM wu21_probe_result;" -c "ROLLBACK;") \
  || fail "WU-21 cycle scope containment probe failed: $probe_result"

for key in \
  typed_consumers_bound legacy_post_close_scope_preserved complete_scopes_available degraded_compatible_restricted degraded_incompatible_blocked \
  incomplete_dependent_blocked incomplete_independent_continues failed_dependent_blocked failed_independent_continues \
  stale_new_exposure_blocked stale_research_restricted blocked_consumer_gate_raises compatible_consumer_gate_allows \
  restricted_consumer_gate_allows profile_scope_policy_rejected historical_effects_excluded \
  unregistered_scope_rejected late_snapshot_rejected inconsistent_manifest_rejected \
  future_cycle_rejected unpublished_post_close_rejected \
  post_close_scope_ledger_exclusive conflicting_scope_effects_rejected no_proven_scope_effects_rejected \
  post_close_scope_source_mismatch_rejected decisions_bind_profiles scope_effect_mismatch_rejected consumer_direct_insert_blocked consumer_delete_blocked \
  scope_effect_source_mismatch_rejected \
  decision_direct_insert_blocked decision_update_blocked consumer_update_blocked decision_truncate_blocked \
  scope_effect_direct_insert_blocked scope_effect_update_blocked scope_effect_truncate_blocked; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "typed consumers receive profile-bound decisions for complete and degraded cycles"
pass "degraded-compatible consumers are restricted while consumers requiring failed scopes are blocked"
pass "incomplete and failed cycles block only their proven failed scope while independent scope continues"
pass "active stale intervals block new exposure and restrict other downstream research use"
pass "the downstream require gate raises for blocked consumers and permits available or restricted consumers"
pass "scope provenance, post-close exclusivity, historical cutoff, and conflict fail-closed branches are probed"
pass "scope mismatch and direct mutation probes isolate the containment mechanisms"

containment_payload=$(jq -c '{complete: .complete_scopes_available, degraded_restricted: .degraded_compatible_restricted, degraded_blocked: .degraded_incompatible_blocked, incomplete_blocked: .incomplete_dependent_blocked, incomplete_independent: .incomplete_independent_continues, failed_blocked: .failed_dependent_blocked, failed_independent: .failed_independent_continues}' <<<"$probe_result")
stale_payload=$(jq -c '{new_exposure_blocked: .stale_new_exposure_blocked, research_restricted: .stale_research_restricted, blocked_gate_raises: .blocked_consumer_gate_raises, compatible_gate_allows: .compatible_consumer_gate_allows}' <<<"$probe_result")
chain_containment=$(append_audit_event "wu21-containment-$(date +%s)" "research.cycle_scope_containment_decided" "$(jq -nc --argjson evidence "$containment_payload" '{probe: "wu21_cycle_scope_containment_probe", evidence: $evidence}')")
chain_stale=$(append_audit_event "wu21-stale-$(date +%s)" "research.cycle_scope_stale_restriction" "$(jq -nc --argjson evidence "$stale_payload" '{probe: "wu21_cycle_scope_containment_probe", evidence: $evidence}')")
[[ "$chain_stale" -gt "$chain_containment" ]] || fail "audit chain positions did not advance: $chain_containment -> $chain_stale"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "containment decisions and stale restrictions are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson migration_head "$migration_head" \
  --arg migration_checksum "$migration_checksum" \
  --arg migration_schema_head "$migration_schema_head" \
  --arg migration_fingerprint "$migration_fingerprint" \
  --arg public_write_revoked "$public_write_revoked" \
  --argjson audit_position_containment "$chain_containment" \
  --argjson audit_position_stale "$chain_stale" \
  '{
    captured_at: $captured_at,
    migration: {
      head: $migration_head,
      expected_head: 22,
      version: 22,
      name: "cycle_scope_containment",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    consumers: {typed_and_profile_bound: $probe.typed_consumers_bound, decisions_bind_profiles: $probe.decisions_bind_profiles},
    compatibility: {legacy_post_close_scope_preserved: $probe.legacy_post_close_scope_preserved},
    containment: {
      complete_scopes_available: $probe.complete_scopes_available,
      degraded_compatible_restricted: $probe.degraded_compatible_restricted,
      degraded_incompatible_blocked: $probe.degraded_incompatible_blocked,
      incomplete_dependent_blocked: $probe.incomplete_dependent_blocked,
      incomplete_independent_continues: $probe.incomplete_independent_continues,
      failed_dependent_blocked: $probe.failed_dependent_blocked,
      failed_independent_continues: $probe.failed_independent_continues
    },
    stale_interval: {new_exposure_blocked: $probe.stale_new_exposure_blocked, research_restricted: $probe.stale_research_restricted, blocked_consumer_gate_raises: $probe.blocked_consumer_gate_raises, compatible_consumer_gate_allows: $probe.compatible_consumer_gate_allows, restricted_consumer_gate_allows: $probe.restricted_consumer_gate_allows},
    containment_guards: {
      profile_scope_policy_rejected: $probe.profile_scope_policy_rejected,
      historical_effects_excluded: $probe.historical_effects_excluded,
      post_close_scope_ledger_exclusive: $probe.post_close_scope_ledger_exclusive,
      conflicting_scope_effects_rejected: $probe.conflicting_scope_effects_rejected,
      no_proven_scope_effects_rejected: $probe.no_proven_scope_effects_rejected,
      unregistered_scope_rejected: $probe.unregistered_scope_rejected,
      late_snapshot_rejected: $probe.late_snapshot_rejected,
      inconsistent_manifest_rejected: $probe.inconsistent_manifest_rejected,
      future_cycle_rejected: $probe.future_cycle_rejected,
      unpublished_post_close_rejected: $probe.unpublished_post_close_rejected,
      scope_effect_source_mismatch_rejected: $probe.scope_effect_source_mismatch_rejected,
      post_close_scope_source_mismatch_rejected: $probe.post_close_scope_source_mismatch_rejected
    },
    append_only_and_fail_closed: {
      scope_effect_mismatch_rejected: $probe.scope_effect_mismatch_rejected,
      consumer_direct_insert_blocked: $probe.consumer_direct_insert_blocked,
      consumer_delete_blocked: $probe.consumer_delete_blocked,
      decision_direct_insert_blocked: $probe.decision_direct_insert_blocked,
      decision_update_blocked: $probe.decision_update_blocked,
      consumer_update_blocked: $probe.consumer_update_blocked,
      decision_truncate_blocked: $probe.decision_truncate_blocked,
      scope_effect_direct_insert_blocked: $probe.scope_effect_direct_insert_blocked,
      scope_effect_update_blocked: $probe.scope_effect_update_blocked,
      scope_effect_truncate_blocked: $probe.scope_effect_truncate_blocked,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {containment: $audit_position_containment, stale: $audit_position_stale}
  }' >"$REPORT" || fail "could not write WU-21 evidence report"
jq -e '
  .migration.head == 22
  and .migration.expected_head == 22
  and .migration.version == 22
  and .migration.name == "cycle_scope_containment"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and (.migration.schema_head | length) > 0
  and (.migration.fingerprint | length) > 0
  and
  .consumers.typed_and_profile_bound == true
  and .consumers.decisions_bind_profiles == true
  and .compatibility.legacy_post_close_scope_preserved == true
  and .containment.complete_scopes_available == true
  and .containment.degraded_compatible_restricted == true
  and .containment.degraded_incompatible_blocked == true
  and .containment.incomplete_dependent_blocked == true
  and .containment.incomplete_independent_continues == true
  and .containment.failed_dependent_blocked == true
  and .containment.failed_independent_continues == true
  and .stale_interval.new_exposure_blocked == true
  and .stale_interval.research_restricted == true
  and .stale_interval.blocked_consumer_gate_raises == true
  and .stale_interval.compatible_consumer_gate_allows == true
  and .stale_interval.restricted_consumer_gate_allows == true
  and .containment_guards.profile_scope_policy_rejected == true
  and .containment_guards.historical_effects_excluded == true
  and .containment_guards.post_close_scope_ledger_exclusive == true
  and .containment_guards.conflicting_scope_effects_rejected == true
  and .containment_guards.no_proven_scope_effects_rejected == true
  and .containment_guards.unregistered_scope_rejected == true
  and .containment_guards.late_snapshot_rejected == true
  and .containment_guards.inconsistent_manifest_rejected == true
  and .containment_guards.future_cycle_rejected == true
  and .containment_guards.unpublished_post_close_rejected == true
  and .containment_guards.scope_effect_source_mismatch_rejected == true
  and .containment_guards.post_close_scope_source_mismatch_rejected == true
  and .append_only_and_fail_closed.scope_effect_mismatch_rejected == true
  and .append_only_and_fail_closed.consumer_direct_insert_blocked == true
  and .append_only_and_fail_closed.consumer_delete_blocked == true
  and .append_only_and_fail_closed.decision_direct_insert_blocked == true
  and .append_only_and_fail_closed.decision_update_blocked == true
  and .append_only_and_fail_closed.consumer_update_blocked == true
  and .append_only_and_fail_closed.decision_truncate_blocked == true
  and .append_only_and_fail_closed.scope_effect_direct_insert_blocked == true
  and .append_only_and_fail_closed.scope_effect_update_blocked == true
  and .append_only_and_fail_closed.scope_effect_truncate_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.stale > .audit_positions.containment
' "$REPORT" >/dev/null || fail "WU-21 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-21 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-21 COMPLETE"
