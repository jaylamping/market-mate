#!/usr/bin/env bash
# WU-20 executable acceptance test — earnings event-driven delta cycles.
# Evidence: event-cycle manifests linked to a post-close parent cycle.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-20"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/event-delta-cycle-report.json"
PROBE_SQL="db/fixtures/wu20_event_delta_cycle_probe.sql"
SOURCE_PROBE_SQL="db/fixtures/wu14_earnings_estimates_probe.sql"
WU20_PROJECT_NAME="${WU20_COMPOSE_PROJECT_NAME:-market-mate-wu20}"
COMPOSE=(docker compose --project-name "$WU20_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-20 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-20 PASS: $1"; }
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
      '{\"source\":\"wu20-acceptance\",\"entitlement_version\":\"event-delta-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq
log "== WU-20 event delta cycle test $(date -u +%FT%TZ) (project: $WU20_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19; do
  [[ "$sibling" == "$WU20_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-20 Compose state"
log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 || fail "Compose bring-up failed"
wait_for_healthy_services 300 || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu20-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-20 probe into the postgres container"
"${COMPOSE[@]}" cp "$SOURCE_PROBE_SQL" postgres:/tmp/wu14-source-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-14 source fixture into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu14-source-probe.sql -f /tmp/wu20-probe.sql \
  -c "SELECT result FROM wu20_probe_result;" -c "ROLLBACK;") \
  || fail "WU-20 event delta cycle probe failed: $probe_result"

for key in \
  earnings_date_triggered eight_k_triggered event_manifests_are_own event_cycles_link_parent \
  event_manifests_recorded event_source_refs_bound source_ref_mismatch_rejected \
  malformed_timestamp_rejected duplicate_event_blocked event_cycle_update_blocked \
  event_manifest_update_blocked; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "earnings-date and 8-K triggers publish distinct event-driven manifests"
pass "event cycles link to the authoritative post-close parent cycle"
pass "event sources are typed, reference-bound, and timestamp-validated"
pass "duplicate event and event-manifest mutation probes fail closed"

event_payload=$(jq -c '{earnings_date: .earnings_date_triggered, eight_k: .eight_k_triggered, own_manifests: .event_manifests_are_own, parent_link: .event_cycles_link_parent, source_refs_bound: .event_source_refs_bound, source_ref_mismatch_rejected: .source_ref_mismatch_rejected, malformed_timestamp_rejected: .malformed_timestamp_rejected}' <<<"$probe_result")
chain_event=$(append_audit_event "wu20-event-$(date +%s)" "research.event_delta_cycle_published" "$(jq -nc --argjson evidence "$event_payload" '{probe: "wu20_event_delta_cycle_probe", evidence: $evidence}')")
chain_link=$(append_audit_event "wu20-link-$(date +%s)" "research.event_delta_cycle_parent_linked" "$(jq -nc --argjson evidence "$event_payload" '{probe: "wu20_event_delta_cycle_probe", evidence: $evidence}')")
[[ "$chain_link" -gt "$chain_event" ]] || fail "audit chain positions did not advance: $chain_event -> $chain_link"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "event-cycle outcomes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson audit_position_event "$chain_event" \
  --argjson audit_position_link "$chain_link" \
  '{
    captured_at: $captured_at,
    triggers: {earnings_date_reached: $probe.earnings_date_triggered, eight_k_detected: $probe.eight_k_triggered},
    manifests: {own_event_manifests: $probe.event_manifests_are_own, parent_cycle_linked: $probe.event_cycles_link_parent, both_recorded: $probe.event_manifests_recorded},
    provenance: {event_source_refs_bound: $probe.event_source_refs_bound, source_ref_mismatch_rejected: $probe.source_ref_mismatch_rejected, malformed_timestamp_rejected: $probe.malformed_timestamp_rejected},
    append_only: {duplicate_event_blocked: $probe.duplicate_event_blocked, event_cycle_update_blocked: $probe.event_cycle_update_blocked, event_manifest_update_blocked: $probe.event_manifest_update_blocked},
    audit_chain: $chain,
    audit_positions: {event: $audit_position_event, parent_link: $audit_position_link}
  }' >"$REPORT" || fail "could not write WU-20 evidence report"
jq -e '
  .triggers.earnings_date_reached == true
  and .triggers.eight_k_detected == true
  and .manifests.own_event_manifests == true
  and .manifests.parent_cycle_linked == true
  and .manifests.both_recorded == true
  and .provenance.event_source_refs_bound == true
  and .provenance.source_ref_mismatch_rejected == true
  and .provenance.malformed_timestamp_rejected == true
  and .append_only.duplicate_event_blocked == true
  and .append_only.event_cycle_update_blocked == true
  and .append_only.event_manifest_update_blocked == true
  and .audit_chain.valid == true
  and .audit_positions.parent_link > .audit_positions.event
' "$REPORT" >/dev/null || fail "WU-20 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-20 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-20 COMPLETE"
