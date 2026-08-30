#!/usr/bin/env bash
# WU-23 executable acceptance test — Discovery Pool screener.
# Evidence: versioned universe, screen run, pool membership, and isolated
# mutation-probe report on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-23"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/discovery-pool-report.json"
PROBE_SQL="db/fixtures/wu23_discovery_pool_probe.sql"
WU23_PROJECT_NAME="${WU23_COMPOSE_PROJECT_NAME:-market-mate-wu23}"
COMPOSE=(docker compose --project-name "$WU23_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-23 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-23 PASS: $1"; }
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
      '{\"source\":\"wu23-acceptance\",\"entitlement_version\":\"coverage-policy-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq
log "== WU-23 Discovery Pool screener test $(date -u +%FT%TZ) (project: $WU23_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22; do
  [[ "$sibling" == "$WU23_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-23 Compose state"
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
[[ "$migration_head" == "24" ]] || fail "expected migration head 24, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 24;") \
  || fail "could not read migration 24 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 24 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 24 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu23-discovery-pool-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-23 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu23-discovery-pool-probe.sql \
  -c "SELECT result FROM wu23_probe_result;" -c "ROLLBACK;") \
  || fail "WU-23 Discovery Pool probe failed: $probe_result"

for key in \
  config_digest_valid config_binds_governing_policy \
  run_complete run_counts_consistent run_digest_valid \
  clean_common_stock_included preferred_rejected_for_class \
  sparse_rejected_for_data otc_tagged_enhanced_risk_not_rejected_by_label \
  uncertified_identity_rejected conflicting_identity_rejected \
  penny_tagged_enhanced_risk_not_rejected_by_price \
  retired_membership_excluded_from_universe thin_rejected_for_liquidity \
  late_membership_invisible_at_run_as_of pricefail_rejected_for_price \
  membership_facts_recorded late_member_hidden_before_receipt \
  late_member_visible_after_receipt deterministic_replay_matches \
  duplicate_run_blocked insufficient_calendar_fails_closed \
  future_as_of_blocked invalid_definition_blocked unknown_policy_blocked \
  config_update_blocked run_update_blocked membership_delete_blocked \
  universe_truncate_blocked run_audited; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "universe, config, run, membership, and screening gates pass"
pass "point-in-time replay, enhanced-risk tagging, and rejection reasons pass"
pass "deterministic replay, duplicate-run, and fail-closed calendar probes pass"
pass "append-only and invalid-input probes fail closed"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.discovery_universe_entry', 'INSERT')
     AND NOT has_table_privilege('public', 'public.discovery_screen_config_version', 'INSERT')
     AND NOT has_table_privilege('public', 'public.discovery_screen_run', 'INSERT')
     AND NOT has_table_privilege('public', 'public.discovery_pool_membership', 'INSERT')
     AND NOT has_function_privilege('public', 'append_discovery_universe_entry(text,text,uuid,date,date,text,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'append_discovery_screen_config_version(text,integer,uuid,jsonb,timestamptz,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'run_discovery_screen(uuid,date,timestamptz,jsonb)', 'EXECUTE');
") || fail "could not inspect public discovery write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public discovery write privileges were not revoked"
pass "public discovery writes are revoked; workflow guards remain the measured local boundary"

screen_payload=$(jq -c '{config_digest_valid, config_binds_governing_policy, run_complete, run_counts_consistent, run_digest_valid, clean_common_stock_included, preferred_rejected_for_class, sparse_rejected_for_data, otc_tagged_enhanced_risk_not_rejected_by_label, uncertified_identity_rejected, conflicting_identity_rejected, penny_tagged_enhanced_risk_not_rejected_by_price, retired_membership_excluded_from_universe, thin_rejected_for_liquidity, late_membership_invisible_at_run_as_of, pricefail_rejected_for_price, membership_facts_recorded}' <<<"$probe_result")
replay_payload=$(jq -c '{late_member_hidden_before_receipt, late_member_visible_after_receipt, deterministic_replay_matches, duplicate_run_blocked, insufficient_calendar_fails_closed, future_as_of_blocked}' <<<"$probe_result")
guard_payload=$(jq -c '{invalid_definition_blocked, unknown_policy_blocked, config_update_blocked, run_update_blocked, membership_delete_blocked, universe_truncate_blocked, run_audited}' <<<"$probe_result")
chain_screen=$(append_audit_event "wu23-screen-$(date +%s)" "research.discovery_pool_screener_proved" "$(jq -nc --argjson evidence "$screen_payload" '{probe: "wu23_discovery_pool_probe", evidence: $evidence}')")
chain_replay=$(append_audit_event "wu23-replay-$(date +%s)" "research.discovery_pool_replay_proved" "$(jq -nc --argjson evidence "$replay_payload" '{probe: "wu23_discovery_pool_probe", evidence: $evidence}')")
chain_guard=$(append_audit_event "wu23-guards-$(date +%s)" "research.discovery_pool_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu23_discovery_pool_probe", evidence: $evidence}')")
[[ "$chain_replay" -gt "$chain_screen" && "$chain_guard" -gt "$chain_replay" ]] \
  || fail "audit chain positions did not advance: $chain_screen -> $chain_replay -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "screening decisions and isolated guard probes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson migration_head "$migration_head" \
  --arg migration_checksum "$migration_checksum" \
  --arg migration_schema_head "$migration_schema_head" \
  --arg migration_fingerprint "$migration_fingerprint" \
  --arg public_write_revoked "$public_write_revoked" \
  --argjson audit_position_screen "$chain_screen" \
  --argjson audit_position_replay "$chain_replay" \
  --argjson audit_position_guards "$chain_guard" \
  '{
    captured_at: $captured_at,
    migration: {
      head: $migration_head,
      expected_head: 24,
      version: 24,
      name: "discovery_pool",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    screening: {
      config_digest_valid: $probe.config_digest_valid,
      config_binds_governing_policy: $probe.config_binds_governing_policy,
      run_complete: $probe.run_complete,
      run_counts_consistent: $probe.run_counts_consistent,
      run_digest_valid: $probe.run_digest_valid,
      clean_common_stock_included: $probe.clean_common_stock_included,
      preferred_rejected_for_class: $probe.preferred_rejected_for_class,
      sparse_rejected_for_data: $probe.sparse_rejected_for_data,
      otc_tagged_enhanced_risk_not_rejected_by_label: $probe.otc_tagged_enhanced_risk_not_rejected_by_label,
      uncertified_identity_rejected: $probe.uncertified_identity_rejected,
      conflicting_identity_rejected: $probe.conflicting_identity_rejected,
      penny_tagged_enhanced_risk_not_rejected_by_price: $probe.penny_tagged_enhanced_risk_not_rejected_by_price,
      retired_membership_excluded_from_universe: $probe.retired_membership_excluded_from_universe,
      thin_rejected_for_liquidity: $probe.thin_rejected_for_liquidity,
      late_membership_invisible_at_run_as_of: $probe.late_membership_invisible_at_run_as_of,
      pricefail_rejected_for_price: $probe.pricefail_rejected_for_price,
      membership_facts_recorded: $probe.membership_facts_recorded
    },
    replay_and_fail_closed: {
      late_member_hidden_before_receipt: $probe.late_member_hidden_before_receipt,
      late_member_visible_after_receipt: $probe.late_member_visible_after_receipt,
      deterministic_replay_matches: $probe.deterministic_replay_matches,
      duplicate_run_blocked: $probe.duplicate_run_blocked,
      insufficient_calendar_fails_closed: $probe.insufficient_calendar_fails_closed,
      future_as_of_blocked: $probe.future_as_of_blocked
    },
    append_only_and_fail_closed: {
      invalid_definition_blocked: $probe.invalid_definition_blocked,
      unknown_policy_blocked: $probe.unknown_policy_blocked,
      config_update_blocked: $probe.config_update_blocked,
      run_update_blocked: $probe.run_update_blocked,
      membership_delete_blocked: $probe.membership_delete_blocked,
      universe_truncate_blocked: $probe.universe_truncate_blocked,
      run_audited: $probe.run_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {screen: $audit_position_screen, replay: $audit_position_replay, guards: $audit_position_guards}
  }' >"$REPORT" || fail "could not write WU-23 evidence report"
jq -e '
  .migration.head == 24
  and .migration.expected_head == 24
  and .migration.version == 24
  and .migration.name == "discovery_pool"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and (.migration.schema_head | length) > 0
  and (.migration.fingerprint | length) > 0
  and .screening.config_digest_valid == true
  and .screening.config_binds_governing_policy == true
  and .screening.run_complete == true
  and .screening.run_counts_consistent == true
  and .screening.run_digest_valid == true
  and .screening.clean_common_stock_included == true
  and .screening.preferred_rejected_for_class == true
  and .screening.sparse_rejected_for_data == true
  and .screening.otc_tagged_enhanced_risk_not_rejected_by_label == true
  and .screening.uncertified_identity_rejected == true
  and .screening.conflicting_identity_rejected == true
  and .screening.penny_tagged_enhanced_risk_not_rejected_by_price == true
  and .screening.retired_membership_excluded_from_universe == true
  and .screening.thin_rejected_for_liquidity == true
  and .screening.late_membership_invisible_at_run_as_of == true
  and .screening.pricefail_rejected_for_price == true
  and .screening.membership_facts_recorded == true
  and .replay_and_fail_closed.late_member_hidden_before_receipt == true
  and .replay_and_fail_closed.late_member_visible_after_receipt == true
  and .replay_and_fail_closed.deterministic_replay_matches == true
  and .replay_and_fail_closed.duplicate_run_blocked == true
  and .replay_and_fail_closed.insufficient_calendar_fails_closed == true
  and .replay_and_fail_closed.future_as_of_blocked == true
  and .append_only_and_fail_closed.invalid_definition_blocked == true
  and .append_only_and_fail_closed.unknown_policy_blocked == true
  and .append_only_and_fail_closed.config_update_blocked == true
  and .append_only_and_fail_closed.run_update_blocked == true
  and .append_only_and_fail_closed.membership_delete_blocked == true
  and .append_only_and_fail_closed.universe_truncate_blocked == true
  and .append_only_and_fail_closed.run_audited == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.replay > .audit_positions.screen
  and .audit_positions.guards > .audit_positions.replay
' "$REPORT" >/dev/null || fail "WU-23 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-23 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-23 COMPLETE"
