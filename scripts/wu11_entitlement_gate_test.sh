#!/usr/bin/env bash
# WU-11 executable acceptance test — entitlement certification gate.
# Evidence: entitlement gate decision report written to evidence/wu-11/.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-11"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/entitlement-gate-report.json"
PROBE_SQL="db/fixtures/wu11_entitlement_gate_probe.sql"
WU11_PROJECT_NAME="${WU11_COMPOSE_PROJECT_NAME:-market-mate-wu11}"
COMPOSE=(docker compose --project-name "$WU11_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() {
  printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"
}

fail() {
  log "WU-11 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}

pass() {
  log "WU-11 PASS: $1"
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
      '{\"source\":\"wu11-acceptance\",\"entitlement_version\":\"local-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq

log "== WU-11 Entitlement certification gate test $(date -u +%FT%TZ) (project: $WU11_PROJECT_NAME) =="

"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose configuration is invalid"

for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10; do
  if [[ "$sibling" == "$WU11_PROJECT_NAME" ]]; then continue; fi
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove prior WU-11 Compose state"

log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose bring-up failed"

wait_for_healthy_services 300 \
  || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

# Run the gate probe in one rolled-back transaction so denial, expiry, and
# provenance evidence exercise the real database functions and constraints.
"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu11-probe.sql \
  >>"$BRING_UP_LOG" 2>&1 || fail "could not copy the entitlement probe into the postgres container"
probe_result=$("${PSQL[@]}" \
  -c "BEGIN;" \
  -f /tmp/wu11-probe.sql \
  -c "SELECT result FROM wu11_probe_result;" \
  -c "ROLLBACK;") \
  || fail "entitlement certification gate probe failed: $probe_result"

for key in \
  uncertified_use_denied uncertified_denial_recorded certified_use_allowed \
  expired_use_denied certified_use_recorded provenance_source_attached \
  provenance_entitlement_attached provenance_receipt_time_attached \
  decision_log_append_only denied_use_blocked; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "uncertified entitlement use fails closed and records a denial"
pass "certified entitlement use is admitted before expiry and past-expiry use is denied"
pass "downstream use receipt carries source, entitlement version, and receipt time provenance"
pass "gate decision log rejects in-place mutation and denied use creates no receipt"

# Material gate outcomes are represented on the verified append-only audit chain.
denial_payload=$(jq -nc \
  --argjson uncertified "$(jq -c '{decision: .uncertified_use_denied, recorded: .uncertified_denial_recorded}' <<<"$probe_result")" \
  --argjson expired "$(jq -c '{decision: .expired_use_denied}' <<<"$probe_result")" \
  '{probe: "wu11_entitlement_gate_probe", uncertified: $uncertified, expired: $expired}')
chain_denial=$(append_audit_event "wu11-denial-$(date +%s)" \
  "entitlement.gate_denied" "$denial_payload")
provenance_payload=$(jq -nc \
  --argjson provenance "$(jq -c '{source: .provenance_source_attached, entitlement: .provenance_entitlement_attached, receipt_time: .provenance_receipt_time_attached}' <<<"$probe_result")" \
  '{probe: "wu11_entitlement_gate_probe", certified_use: true, provenance: $provenance}')
chain_provenance=$(append_audit_event "wu11-provenance-$(date +%s)" \
  "entitlement.use_provenance_attached" "$provenance_payload")
[[ "$chain_provenance" -gt "$chain_denial" ]] \
  || fail "audit chain positions did not advance: $chain_denial -> $chain_provenance"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null \
  || fail "audit chain does not verify: $chain_ok"
pass "entitlement denials and provenance-bearing use recorded on the verified audit chain"

# Assemble and validate the named evidence artifact.
jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson audit_position_denial "$chain_denial" \
  --argjson audit_position_provenance "$chain_provenance" \
  '{
    captured_at: $captured_at,
    entitlement_gate: {
      uncertified_use_denied: $probe.uncertified_use_denied,
      denial_recorded: $probe.uncertified_denial_recorded,
      certified_use_allowed: $probe.certified_use_allowed,
      expired_use_denied: $probe.expired_use_denied,
      decision_log_append_only: $probe.decision_log_append_only,
      denied_use_blocked: $probe.denied_use_blocked
    },
    provenance: {
      use_receipt_recorded: $probe.certified_use_recorded,
      source_registry_version_attached: $probe.provenance_source_attached,
      entitlement_version_attached: $probe.provenance_entitlement_attached,
      receipt_time_attached: $probe.provenance_receipt_time_attached
    },
    audit_chain: $chain,
    audit_positions: {
      denial: $audit_position_denial,
      provenance: $audit_position_provenance
    }
  }' >"$REPORT" \
  || fail "could not write entitlement gate report"

jq -e '
  .entitlement_gate.uncertified_use_denied == true
  and .entitlement_gate.denial_recorded == true
  and .entitlement_gate.certified_use_allowed == true
  and .entitlement_gate.expired_use_denied == true
  and .entitlement_gate.decision_log_append_only == true
  and .entitlement_gate.denied_use_blocked == true
  and .provenance.use_receipt_recorded == true
  and .provenance.source_registry_version_attached == true
  and .provenance.entitlement_version_attached == true
  and .provenance.receipt_time_attached == true
  and .audit_chain.valid == true
  and .audit_positions.denial > 0
  and .audit_positions.provenance > 0
' "$REPORT" >/dev/null \
  || fail "entitlement gate report does not satisfy the WU-11 evidence schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] \
  || fail "named WU-11 evidence is not retrievable"

pass "valid evidence is retrievable at $REPORT"
log "WU-11 COMPLETE"
