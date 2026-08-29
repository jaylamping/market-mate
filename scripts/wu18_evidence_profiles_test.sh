#!/usr/bin/env bash
# WU-18 executable acceptance test — typed evidence profiles and obligations.
# Evidence: profile resolution and Not Applicable proof-rule report.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-18"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/evidence-profile-resolution-report.json"
PROBE_SQL="db/fixtures/wu18_evidence_profiles_probe.sql"
WU18_PROJECT_NAME="${WU18_COMPOSE_PROJECT_NAME:-market-mate-wu18}"
COMPOSE=(docker compose --project-name "$WU18_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-18 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-18 PASS: $1"; }
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
      '{\"source\":\"wu18-acceptance\",\"entitlement_version\":\"evidence-profile-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq
log "== WU-18 Evidence Profile test $(date -u +%FT%TZ) (project: $WU18_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17; do
  [[ "$sibling" == "$WU18_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-18 Compose state"
log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 || fail "Compose bring-up failed"
wait_for_healthy_services 300 || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu18-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-18 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu18-probe.sql \
  -c "SELECT result FROM wu18_probe_result;" -c "ROLLBACK;") \
  || fail "WU-18 Evidence Profile probe failed: $probe_result"

for key in \
  universal_profile_resolved options_profile_resolved holding_profile_resolved portfolio_profile_resolved \
  profiles_are_typed_and_distinct not_applicable_has_proved_rule no_default_substitution_in_profiles \
  unproved_not_applicable_blocked resolution_update_blocked obligation_update_blocked; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "stage, capability, and decision purpose resolve distinct typed profiles"
pass "Not Applicable obligations carry a proved contract rule without a default substitute"
pass "unproved Not Applicable and evidence-profile mutations fail closed"

profile_payload=$(jq -c '{universal: .universal_profile_resolved, options: .options_profile_resolved, holding: .holding_profile_resolved, portfolio: .portfolio_profile_resolved, distinct: .profiles_are_typed_and_distinct}' <<<"$probe_result")
obligation_payload=$(jq -c '{proved_not_applicable: .not_applicable_has_proved_rule, no_default: .no_default_substitution_in_profiles, unproved_blocked: .unproved_not_applicable_blocked}' <<<"$probe_result")
chain_profile=$(append_audit_event "wu18-profile-$(date +%s)" "research.evidence_profile_resolved" "$(jq -nc --argjson evidence "$profile_payload" '{probe: "wu18_evidence_profiles_probe", evidence: $evidence}')")
chain_obligation=$(append_audit_event "wu18-obligation-$(date +%s)" "research.evidence_obligation_proved" "$(jq -nc --argjson evidence "$obligation_payload" '{probe: "wu18_evidence_profiles_probe", evidence: $evidence}')")
[[ "$chain_obligation" -gt "$chain_profile" ]] || fail "audit chain positions did not advance: $chain_profile -> $chain_obligation"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "profile resolution and obligation proof are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson audit_position_profile "$chain_profile" \
  --argjson audit_position_obligation "$chain_obligation" \
  '{
    captured_at: $captured_at,
    profiles: {universal: $probe.universal_profile_resolved, options: $probe.options_profile_resolved, holding: $probe.holding_profile_resolved, portfolio: $probe.portfolio_profile_resolved, typed_and_distinct: $probe.profiles_are_typed_and_distinct},
    obligations: {not_applicable_has_proved_rule: $probe.not_applicable_has_proved_rule, no_default_substitution: $probe.no_default_substitution_in_profiles, unproved_not_applicable_blocked: $probe.unproved_not_applicable_blocked},
    append_only: {resolution_update_blocked: $probe.resolution_update_blocked, obligation_update_blocked: $probe.obligation_update_blocked},
    audit_chain: $chain,
    audit_positions: {profile: $audit_position_profile, obligation: $audit_position_obligation}
  }' >"$REPORT" || fail "could not write WU-18 evidence report"
jq -e '
  .profiles.universal == true
  and .profiles.options == true
  and .profiles.holding == true
  and .profiles.portfolio == true
  and .profiles.typed_and_distinct == true
  and .obligations.not_applicable_has_proved_rule == true
  and .obligations.no_default_substitution == true
  and .obligations.unproved_not_applicable_blocked == true
  and .append_only.resolution_update_blocked == true
  and .append_only.obligation_update_blocked == true
  and .audit_chain.valid == true
  and .audit_positions.obligation > .audit_positions.profile
' "$REPORT" >/dev/null || fail "WU-18 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-18 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-18 COMPLETE"
