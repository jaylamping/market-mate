#!/usr/bin/env bash
# WU-19 executable acceptance test — structured Research Evidence Deltas.
# Evidence: delta category coverage, dependency changes, and prose authority report.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-19"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/evidence-delta-report.json"
PROBE_SQL="db/fixtures/wu19_evidence_delta_probe.sql"
WU19_PROJECT_NAME="${WU19_COMPOSE_PROJECT_NAME:-market-mate-wu19}"
COMPOSE=(docker compose --project-name "$WU19_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-19 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-19 PASS: $1"; }
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
      '{\"source\":\"wu19-acceptance\",\"entitlement_version\":\"evidence-delta-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq
log "== WU-19 Evidence Delta test $(date -u +%FT%TZ) (project: $WU19_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18; do
  [[ "$sibling" == "$WU19_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-19 Compose state"
log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 || fail "Compose bring-up failed"
wait_for_healthy_services 300 || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu19-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-19 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu19-probe.sql \
  -c "SELECT result FROM wu19_probe_result;" -c "ROLLBACK;") \
  || fail "WU-19 Evidence Delta probe failed: $probe_result"

for key in \
  delta_covers_additions delta_covers_removals delta_covers_corrections delta_covers_expiry \
  delta_covers_observation_state_changes delta_covers_indicator_changes \
  delta_covers_newly_blocked_dependency delta_covers_restored_dependency delta_digest_bound \
  generated_prose_non_authoritative prose_digest_bound delta_update_blocked prose_update_blocked; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "delta covers additions, removals, corrections, expiry, and observation-state changes"
pass "delta covers indicator changes and newly blocked/restored dependencies"
pass "generated prose is digest-bound and explicitly non-authoritative"
pass "delta and prose mutation probes isolate append-only guards"

delta_payload=$(jq -c '{additions: .delta_covers_additions, removals: .delta_covers_removals, corrections: .delta_covers_corrections, expiry: .delta_covers_expiry, states: .delta_covers_observation_state_changes}' <<<"$probe_result")
dependency_payload=$(jq -c '{indicators: .delta_covers_indicator_changes, newly_blocked: .delta_covers_newly_blocked_dependency, restored: .delta_covers_restored_dependency, prose_non_authoritative: .generated_prose_non_authoritative}' <<<"$probe_result")
chain_delta=$(append_audit_event "wu19-delta-$(date +%s)" "research.evidence_delta_computed" "$(jq -nc --argjson evidence "$delta_payload" '{probe: "wu19_evidence_delta_probe", evidence: $evidence}')")
chain_dependency=$(append_audit_event "wu19-dependency-$(date +%s)" "research.evidence_delta_dependencies_changed" "$(jq -nc --argjson evidence "$dependency_payload" '{probe: "wu19_evidence_delta_probe", evidence: $evidence}')")
[[ "$chain_dependency" -gt "$chain_delta" ]] || fail "audit chain positions did not advance: $chain_delta -> $chain_dependency"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "delta outcomes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson audit_position_delta "$chain_delta" \
  --argjson audit_position_dependency "$chain_dependency" \
  '{
    captured_at: $captured_at,
    delta_categories: {additions: $probe.delta_covers_additions, removals: $probe.delta_covers_removals, corrections: $probe.delta_covers_corrections, expiry: $probe.delta_covers_expiry, observation_state_changes: $probe.delta_covers_observation_state_changes, indicator_changes: $probe.delta_covers_indicator_changes},
    dependencies: {newly_blocked: $probe.delta_covers_newly_blocked_dependency, restored: $probe.delta_covers_restored_dependency},
    prose: {digest_bound: $probe.prose_digest_bound, non_authoritative: $probe.generated_prose_non_authoritative},
    append_only: {delta_update_blocked: $probe.delta_update_blocked, prose_update_blocked: $probe.prose_update_blocked},
    audit_chain: $chain,
    audit_positions: {delta: $audit_position_delta, dependency: $audit_position_dependency}
  }' >"$REPORT" || fail "could not write WU-19 evidence report"
jq -e '
  .delta_categories.additions == true
  and .delta_categories.removals == true
  and .delta_categories.corrections == true
  and .delta_categories.expiry == true
  and .delta_categories.observation_state_changes == true
  and .delta_categories.indicator_changes == true
  and .dependencies.newly_blocked == true
  and .dependencies.restored == true
  and .prose.digest_bound == true
  and .prose.non_authoritative == true
  and .append_only.delta_update_blocked == true
  and .append_only.prose_update_blocked == true
  and .audit_chain.valid == true
  and .audit_positions.dependency > .audit_positions.delta
' "$REPORT" >/dev/null || fail "WU-19 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-19 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-19 COMPLETE"
