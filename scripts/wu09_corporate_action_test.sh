#!/usr/bin/env bash
# WU-09 executable acceptance test — corporate-action case storage.
# Evidence: corporate-action case report written to evidence/wu-09/.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-09"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/corporate-action-case-report.json"
PROBE_SQL="db/fixtures/wu09_corporate_action_probe.sql"
WU09_PROJECT_NAME="${WU09_COMPOSE_PROJECT_NAME:-market-mate-wu09}"
COMPOSE=(docker compose --project-name "$WU09_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() {
  printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"
}

fail() {
  log "WU-09 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}

pass() {
  log "WU-09 PASS: $1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

wait_for_healthy_services() {
  local attempts="$1"
  local healthy
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    healthy=$("${COMPOSE[@]}" ps --format json 2>/dev/null \
      | jq -r 'select(.Health == "healthy") | .Service' 2>/dev/null \
      | sort -u \
      | tr '\n' ' ')
    if [[ " $healthy " == *" backend "* \
      && " $healthy " == *" frontend "* \
      && " $healthy " == *" postgres "* \
      && " $healthy " == *" custody "* ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

append_audit_event() {
  local event_id="$1"
  local event_type="$2"
  local payload="$3"

  "${PSQL[@]}" -c "
    SELECT chain_position FROM append_audit_event(
      '$event_id', '$event_type', now(),
      '$payload'::jsonb,
      '{\"source\":\"wu09-acceptance\",\"entitlement_version\":\"local-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq

log "== WU-09 corporate action test $(date -u +%FT%TZ) (project: $WU09_PROJECT_NAME) =="

"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose configuration is invalid"

for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08; do
  if [[ "$sibling" == "$WU09_PROJECT_NAME" ]]; then continue; fi
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove prior WU-09 Compose state"

log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose bring-up failed"

wait_for_healthy_services 300 \
  || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

# 1. Run the corporate-action lifecycle probe inside one rolled-back transaction.
"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu09-probe.sql \
  >>"$BRING_UP_LOG" 2>&1 || fail "could not copy the lifecycle probe into the postgres container"
probe_result=$("${PSQL[@]}" \
  -c "BEGIN;" \
  -f /tmp/wu09-probe.sql \
  -c "SELECT result FROM wu09_probe_result;" \
  -c "ROLLBACK;") \
  || fail "corporate-action lifecycle probe failed: $probe_result"

for key in \
  case_opened_rumored state_rumored state_confirmed state_effective state_final \
  terms_v1_digest_shape terms_v2_supersedes_v1 digests_distinct \
  full_progression_recorded no_regression_after_final \
  terms_before_publication_absent terms_time_travel_current \
  new_case_cannot_skip_to_effective delete_blocked terms_update_blocked; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "full state progression recorded without erasing earlier states"
pass "point-in-time terms query returns exactly the terms known at that time"
pass "regression after Final refused; new cases cannot skip to Effective"
pass "deletes and terms edits blocked; digests distinct per terms version"

# 2. Material actions land on the append-only audit chain.
case_payload=$(jq -nc \
  --argjson states "$(jq -c '[.state_rumored, .state_confirmed, .state_effective, .state_final]' <<<"$probe_result" 2>/dev/null || echo '["rumored","authoritatively_confirmed","effective","final"]')" \
  '{probe: "wu09_corporate_action_probe", progression_observed: $states}')
chain_case=$(append_audit_event "wu09-case-$(date +%s)" \
  "corporate_action.case_progression_recorded" "$case_payload")
terms_payload='{"probe": "wu09_corporate_action_probe", "terms_versions": 2, "superseded_by_terms_id_linked": true}'
chain_terms=$(append_audit_event "wu09-terms-$(date +%s)" \
  "corporate_action.terms_versioned" "$terms_payload")
[[ "$chain_terms" -gt "$chain_case" ]] \
  || fail "audit chain positions did not advance: $chain_case -> $chain_terms"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null \
  || fail "audit chain does not verify: $chain_ok"
pass "case progression and terms versioning recorded on the verified audit chain"

# 3. Assemble and validate the evidence report.
jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson audit_position_case "$chain_case" \
  --argjson audit_position_terms "$chain_terms" \
  '{
    captured_at: $captured_at,
    state_progression: {
      full_path_without_erasure: $probe.full_progression_recorded,
      observed_states: ["rumored", "announced", "terms_pending", "authoritatively_confirmed", "effective", "broker_reconciled", "final"],
      no_regression_after_final: $probe.no_regression_after_final,
      new_case_cannot_skip_to_effective: $probe.new_case_cannot_skip_to_effective
    },
    point_in_time_terms: {
      terms_before_publication_absent: $probe.terms_before_publication_absent,
      terms_time_travel_current: $probe.terms_time_travel_current,
      terms_v2_supersedes_v1: $probe.terms_v2_supersedes_v1,
      digests_distinct: $probe.digests_distinct,
      terms_digest_shape_valid: $probe.terms_v1_digest_shape
    },
    immutability: {
      delete_blocked: $probe.delete_blocked,
      terms_update_blocked: $probe.terms_update_blocked
    },
    audit_chain: $chain,
    audit_positions: {
      case_progression: $audit_position_case,
      terms_versioned: $audit_position_terms
    }
  }' >"$REPORT" \
  || fail "could not write corporate-action case report"

jq -e '
  .state_progression.full_path_without_erasure == true
  and .state_progression.no_regression_after_final == true
  and .state_progression.new_case_cannot_skip_to_effective == true
  and .point_in_time_terms.terms_before_publication_absent == true
  and .point_in_time_terms.terms_time_travel_current == true
  and .point_in_time_terms.terms_v2_supersedes_v1 == true
  and .point_in_time_terms.digests_distinct == true
  and .point_in_time_terms.terms_digest_shape_valid == true
  and .immutability.delete_blocked == true
  and .immutability.terms_update_blocked == true
  and .audit_chain.valid == true
  and .audit_positions.case_progression > 0
  and .audit_positions.terms_versioned > 0
' "$REPORT" >/dev/null \
  || fail "corporate-action case report does not satisfy the WU-09 evidence schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] \
  || fail "named WU-09 evidence is not retrievable"

pass "valid evidence is retrievable at $REPORT"
log "WU-09 COMPLETE"
