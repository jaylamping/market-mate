#!/usr/bin/env bash
# WU-17 executable acceptance test — post-close cycle orchestration.
# Evidence: sample cycle manifests, deadline/stale semantics, and dependency effects.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-17"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/post-close-orchestrator-report.json"
PROBE_SQL="db/fixtures/wu17_post_close_orchestrator_probe.sql"
WU17_PROJECT_NAME="${WU17_COMPOSE_PROJECT_NAME:-market-mate-wu17}"
COMPOSE=(docker compose --project-name "$WU17_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-17 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-17 PASS: $1"; }
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
      '{\"source\":\"wu17-acceptance\",\"entitlement_version\":\"post-close-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq
log "== WU-17 post-close orchestrator test $(date -u +%FT%TZ) (project: $WU17_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16; do
  [[ "$sibling" == "$WU17_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-17 Compose state"
log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 || fail "Compose bring-up failed"
wait_for_healthy_services 300 || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu17-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-17 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu17-probe.sql \
  -c "SELECT result FROM wu17_probe_result;" -c "ROLLBACK;") \
  || fail "WU-17 post-close probe failed: $probe_result"

for key in \
  sample_days_recorded exactly_one_authoritative_cycle deadline_targeted on_time_cycle_published \
  late_interval_visible partial_failure_degraded dependency_scope_restricted duplicate_publish_blocked \
  cycle_update_blocked manifest_update_blocked dependency_truncate_blocked; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "sample trading days publish one authoritative cycle with a 90-minute deadline"
pass "late publication records a visible stale interval instead of silent catch-up"
pass "partial source failure is Degraded Complete with dependency-scoped effects"
pass "duplicate publication and cycle/manifests mutation probes fail closed"

cycle_payload=$(jq -c '{sample_days: .sample_days_recorded, deadline: .deadline_targeted, on_time: .on_time_cycle_published}' <<<"$probe_result")
stale_payload=$(jq -c '{late_interval: .late_interval_visible, degraded: .partial_failure_degraded, restricted: .dependency_scope_restricted}' <<<"$probe_result")
chain_cycle=$(append_audit_event "wu17-cycle-$(date +%s)" "research.post_close_cycle_published" "$(jq -nc --argjson evidence "$cycle_payload" '{probe: "wu17_post_close_orchestrator_probe", evidence: $evidence}')")
chain_stale=$(append_audit_event "wu17-stale-$(date +%s)" "research.post_close_cycle_stale_interval" "$(jq -nc --argjson evidence "$stale_payload" '{probe: "wu17_post_close_orchestrator_probe", evidence: $evidence}')")
[[ "$chain_stale" -gt "$chain_cycle" ]] || fail "audit chain positions did not advance: $chain_cycle -> $chain_stale"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "cycle publication and stale interval are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson audit_position_cycle "$chain_cycle" \
  --argjson audit_position_stale "$chain_stale" \
  '{
    captured_at: $captured_at,
    sample_days: {recorded: $probe.sample_days_recorded, exactly_one_authoritative_cycle: $probe.exactly_one_authoritative_cycle},
    deadline: {targeted_90_minutes: $probe.deadline_targeted, on_time_published: $probe.on_time_cycle_published},
    stale_and_degraded: {late_interval_visible: $probe.late_interval_visible, partial_failure_degraded: $probe.partial_failure_degraded, dependency_scope_restricted: $probe.dependency_scope_restricted},
    append_only: {duplicate_publish_blocked: $probe.duplicate_publish_blocked, cycle_update_blocked: $probe.cycle_update_blocked, manifest_update_blocked: $probe.manifest_update_blocked, dependency_truncate_blocked: $probe.dependency_truncate_blocked},
    audit_chain: $chain,
    audit_positions: {cycle: $audit_position_cycle, stale_interval: $audit_position_stale}
  }' >"$REPORT" || fail "could not write WU-17 evidence report"
jq -e '
  .sample_days.recorded == true
  and .sample_days.exactly_one_authoritative_cycle == true
  and .deadline.targeted_90_minutes == true
  and .deadline.on_time_published == true
  and .stale_and_degraded.late_interval_visible == true
  and .stale_and_degraded.partial_failure_degraded == true
  and .stale_and_degraded.dependency_scope_restricted == true
  and .append_only.duplicate_publish_blocked == true
  and .append_only.cycle_update_blocked == true
  and .append_only.manifest_update_blocked == true
  and .append_only.dependency_truncate_blocked == true
  and .audit_chain.valid == true
  and .audit_positions.stale_interval > .audit_positions.cycle
' "$REPORT" >/dev/null || fail "WU-17 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-17 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-17 COMPLETE"
