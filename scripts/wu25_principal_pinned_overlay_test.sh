#!/usr/bin/env bash
# WU-25 executable acceptance test — Principal-Pinned Overlay.
# Evidence: pin workflow demo record on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-25"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/principal-pinned-overlay-report.json"
PROBE_SQL="db/fixtures/wu25_principal_pinned_overlay_probe.sql"
WU25_PROJECT_NAME="${WU25_COMPOSE_PROJECT_NAME:-market-mate-wu25}"
COMPOSE=(docker compose --project-name "$WU25_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-25 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-25 PASS: $1"; }
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
      '{\"source\":\"wu25-acceptance\",\"entitlement_version\":\"coverage-policy-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-25 Principal-Pinned Overlay test $(date -u +%FT%TZ) (project: $WU25_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu26 market-mate-wu27 market-mate-wu28; do
  [[ "$sibling" == "$WU25_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-25 Compose state"
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
[[ "$migration_head" == "27" ]] || fail "expected migration head 27, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 27;") \
  || fail "could not read migration 27 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 27 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 27 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu25-principal-pinned-overlay-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-25 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu25-principal-pinned-overlay-probe.sql \
  -c "SELECT result FROM wu25_probe_result;" -c "ROLLBACK;") \
  || fail "WU-25 Principal-Pinned Overlay probe failed: $probe_result"

for key in \
  universe_seeded nominations_recorded five_active_pins \
  pins_are_research_candidates pins_not_system_selected \
  overlay_does_not_consume_capacity review_at_is_30_days warning_is_7_days_before_review \
  obligations_active sixth_pin_blocked duplicate_active_pin_blocked \
  system_selected_pin_blocked demotion_frees_overlay_slot \
  unpinned_promotion_still_allowed pin_blocks_promotion pin_prevents_archive \
  pin_cannot_block_safety_demotion demoted_pin_not_active \
  expire_before_review_blocked renewal_reason_required renewal_supersedes \
  revival_blocked trade_eligible_write_blocked \
  direct_insert_blocked pin_update_blocked nomination_delete_blocked \
  pin_audited demotion_audited late_demotion_invisible_before_receipt; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "overlay pins five Principal-Nominated Candidates as Research Candidates"
pass "pins do not consume system-selected capacity and cannot grant Trade Eligible"
pass "pins cannot prevent safety demotion; demotion frees an overlay slot"
pass "append-only, capacity, and invalid-input probes fail closed"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.principal_nominated_candidate', 'INSERT')
     AND NOT has_table_privilege('public', 'public.principal_pin', 'INSERT')
     AND NOT has_table_privilege('public', 'public.principal_pin_lifecycle', 'INSERT')
     AND NOT has_function_privilege('public', 'nominate_principal_candidate(uuid,text,text,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'pin_principal_overlay(uuid,uuid,text,timestamptz,uuid,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'record_principal_pin_lifecycle(uuid,text,text,uuid,jsonb)', 'EXECUTE');
") || fail "could not inspect public overlay write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public overlay write privileges were not revoked"
pass "public overlay writes are revoked; workflow guards remain the measured local boundary"

overlay_payload=$(jq -c '{universe_seeded, nominations_recorded, five_active_pins, pins_are_research_candidates, pins_not_system_selected, overlay_does_not_consume_capacity, review_at_is_30_days, warning_is_7_days_before_review, obligations_active}' <<<"$probe_result")
gate_payload=$(jq -c '{sixth_pin_blocked, duplicate_active_pin_blocked, system_selected_pin_blocked, demotion_frees_overlay_slot, unpinned_promotion_still_allowed, pin_blocks_promotion, pin_prevents_archive, pin_cannot_block_safety_demotion, demoted_pin_not_active}' <<<"$probe_result")
guard_payload=$(jq -c '{expire_before_review_blocked, renewal_reason_required, renewal_supersedes, revival_blocked, trade_eligible_write_blocked, direct_insert_blocked, pin_update_blocked, nomination_delete_blocked, pin_audited, demotion_audited, late_demotion_invisible_before_receipt}' <<<"$probe_result")
chain_overlay=$(append_audit_event "wu25-overlay-$(date +%s)" "research.principal_pinned_overlay_proved" "$(jq -nc --argjson evidence "$overlay_payload" '{probe: "wu25_principal_pinned_overlay_probe", evidence: $evidence}')") \
  || fail "audit append principal_pinned_overlay_proved failed"
chain_gate=$(append_audit_event "wu25-gates-$(date +%s)" "research.principal_pin_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu25_principal_pinned_overlay_probe", evidence: $evidence}')") \
  || fail "audit append principal_pin_gates_proved failed"
chain_guard=$(append_audit_event "wu25-guards-$(date +%s)" "research.principal_pin_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu25_principal_pinned_overlay_probe", evidence: $evidence}')") \
  || fail "audit append principal_pin_guards_probed failed"
[[ "$chain_gate" -gt "$chain_overlay" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_overlay -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "overlay, gates, and isolated guard probes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson migration_head "$migration_head" \
  --arg migration_checksum "$migration_checksum" \
  --arg migration_schema_head "$migration_schema_head" \
  --arg migration_fingerprint "$migration_fingerprint" \
  --arg public_write_revoked "$public_write_revoked" \
  --argjson audit_position_overlay "$chain_overlay" \
  --argjson audit_position_gates "$chain_gate" \
  --argjson audit_position_guards "$chain_guard" \
  '{
    captured_at: $captured_at,
    migration: {
      head: $migration_head,
      expected_head: 27,
      version: 27,
      name: "principal_pinned_overlay",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    overlay: {
      universe_seeded: $probe.universe_seeded,
      nominations_recorded: $probe.nominations_recorded,
      five_active_pins: $probe.five_active_pins,
      pins_are_research_candidates: $probe.pins_are_research_candidates,
      pins_not_system_selected: $probe.pins_not_system_selected,
      overlay_does_not_consume_capacity: $probe.overlay_does_not_consume_capacity,
      review_at_is_30_days: $probe.review_at_is_30_days,
      warning_is_7_days_before_review: $probe.warning_is_7_days_before_review,
      obligations_active: $probe.obligations_active
    },
    gates: {
      sixth_pin_blocked: $probe.sixth_pin_blocked,
      duplicate_active_pin_blocked: $probe.duplicate_active_pin_blocked,
      system_selected_pin_blocked: $probe.system_selected_pin_blocked,
      demotion_frees_overlay_slot: $probe.demotion_frees_overlay_slot,
      unpinned_promotion_still_allowed: $probe.unpinned_promotion_still_allowed,
      pin_blocks_promotion: $probe.pin_blocks_promotion,
      pin_prevents_archive: $probe.pin_prevents_archive,
      pin_cannot_block_safety_demotion: $probe.pin_cannot_block_safety_demotion,
      demoted_pin_not_active: $probe.demoted_pin_not_active
    },
    append_only_and_fail_closed: {
      expire_before_review_blocked: $probe.expire_before_review_blocked,
      renewal_reason_required: $probe.renewal_reason_required,
      renewal_supersedes: $probe.renewal_supersedes,
      revival_blocked: $probe.revival_blocked,
      trade_eligible_write_blocked: $probe.trade_eligible_write_blocked,
      direct_insert_blocked: $probe.direct_insert_blocked,
      pin_update_blocked: $probe.pin_update_blocked,
      nomination_delete_blocked: $probe.nomination_delete_blocked,
      pin_audited: $probe.pin_audited,
      demotion_audited: $probe.demotion_audited,
      late_demotion_invisible_before_receipt: $probe.late_demotion_invisible_before_receipt,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      overlay: $audit_position_overlay,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-25 evidence report"
jq -e '
  .migration.head == 27
  and .migration.expected_head == 27
  and .migration.name == "principal_pinned_overlay"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .overlay.five_active_pins == true
  and .overlay.overlay_does_not_consume_capacity == true
  and .overlay.pins_are_research_candidates == true
  and .overlay.obligations_active == true
  and .gates.sixth_pin_blocked == true
  and .gates.pin_blocks_promotion == true
  and .gates.unpinned_promotion_still_allowed == true
  and .gates.pin_cannot_block_safety_demotion == true
  and .gates.demotion_frees_overlay_slot == true
  and .append_only_and_fail_closed.renewal_supersedes == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.overlay
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-25 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-25 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-25 COMPLETE"
