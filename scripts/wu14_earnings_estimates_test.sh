#!/usr/bin/env bash
# WU-14 executable acceptance test — as-of earnings estimates and EDGAR reconciliation.
# Evidence: estimates corpus, reconciliation manifest, and provenance checks.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-14"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/earnings-estimates-lineage-report.json"
PROBE_SQL="db/fixtures/wu14_earnings_estimates_probe.sql"
WU14_PROJECT_NAME="${WU14_COMPOSE_PROJECT_NAME:-market-mate-wu14}"
COMPOSE=(docker compose --project-name "$WU14_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-14 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-14 PASS: $1"; }
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
      '{\"source\":\"wu14-acceptance\",\"entitlement_version\":\"earnings-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq
log "== WU-14 earnings estimates test $(date -u +%FT%TZ) (project: $WU14_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13; do
  [[ "$sibling" == "$WU14_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-14 Compose state"
log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 || fail "Compose bring-up failed"
wait_for_healthy_services 300 || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu14-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-14 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu14-probe.sql \
  -c "SELECT result FROM wu14_probe_result;" -c "ROLLBACK;") \
  || fail "WU-14 connector probe failed: $probe_result"

for key in \
  estimate_ingested as_of_timestamp_attached announcement_timestamp_attached \
  missing_as_of_rejected actual_edgar_linked announcement_linked disagreement_surfaced \
  reconciliation_provenance_attached connector_contract_bound mismatched_period_rejected unit_currency_mismatch_rejected entitlement_gate_allowed entitled_uses_recorded \
  estimate_update_blocked reconciliation_update_blocked reconciliation_truncate_blocked; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "every estimate carries announcement and as-of timestamps; missing as-of is rejected"
pass "EDGAR actuals reconcile through certified issuer identity and surface disagreement"
pass "mismatched estimate and actual fiscal periods fail closed"
pass "estimate, EDGAR, and reconciliation provenance carries exact source and entitlement versions"
pass "direct mutation probes isolate append-only estimate and reconciliation guards"

estimate_payload=$(jq -c '{estimate: .estimate_ingested, as_of: .as_of_timestamp_attached, announcement: .announcement_timestamp_attached, missing_as_of_rejected: .missing_as_of_rejected}' <<<"$probe_result")
reconciliation_payload=$(jq -c '{actual_edgar_linked: .actual_edgar_linked, announcement_linked: .announcement_linked, disagreement: .disagreement_surfaced, mismatched_period_rejected: .mismatched_period_rejected, unit_currency_mismatch_rejected: .unit_currency_mismatch_rejected, provenance: .reconciliation_provenance_attached}' <<<"$probe_result")
chain_estimate=$(append_audit_event "wu14-estimate-$(date +%s)" "earnings.estimate_ingested" "$(jq -nc --argjson evidence "$estimate_payload" '{probe: "wu14_earnings_estimates_probe", evidence: $evidence}')")
chain_reconciliation=$(append_audit_event "wu14-reconciliation-$(date +%s)" "earnings.actual_reconciled" "$(jq -nc --argjson evidence "$reconciliation_payload" '{probe: "wu14_earnings_estimates_probe", evidence: $evidence}')")
[[ "$chain_reconciliation" -gt "$chain_estimate" ]] || fail "audit chain positions did not advance: $chain_estimate -> $chain_reconciliation"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "earnings estimate and reconciliation outcomes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson audit_position_estimate "$chain_estimate" \
  --argjson audit_position_reconciliation "$chain_reconciliation" \
  '{
    captured_at: $captured_at,
    estimates: {
      ingested: $probe.estimate_ingested,
      as_of_timestamp_attached: $probe.as_of_timestamp_attached,
      announcement_timestamp_attached: $probe.announcement_timestamp_attached,
      missing_as_of_rejected: $probe.missing_as_of_rejected
    },
    reconciliation: {
      actual_edgar_linked: $probe.actual_edgar_linked,
      announcement_linked: $probe.announcement_linked,
      disagreement_surfaced: $probe.disagreement_surfaced,
      mismatched_period_rejected: $probe.mismatched_period_rejected,
      unit_currency_mismatch_rejected: $probe.unit_currency_mismatch_rejected,
      provenance_attached: $probe.reconciliation_provenance_attached,
      connector_contract_bound: $probe.connector_contract_bound
    },
    entitlement: {
      gate_allowed: $probe.entitlement_gate_allowed,
      uses_recorded: $probe.entitled_uses_recorded
    },
    append_only: {
      estimate_update_blocked: $probe.estimate_update_blocked,
      reconciliation_update_blocked: $probe.reconciliation_update_blocked,
      reconciliation_truncate_blocked: $probe.reconciliation_truncate_blocked
    },
    audit_chain: $chain,
    audit_positions: {estimate: $audit_position_estimate, reconciliation: $audit_position_reconciliation}
  }' >"$REPORT" || fail "could not write WU-14 evidence report"
jq -e '
  .estimates.ingested == true
  and .estimates.as_of_timestamp_attached == true
  and .estimates.announcement_timestamp_attached == true
  and .estimates.missing_as_of_rejected == true
  and .reconciliation.actual_edgar_linked == true
  and .reconciliation.announcement_linked == true
  and .reconciliation.disagreement_surfaced == true
  and .reconciliation.mismatched_period_rejected == true
  and .reconciliation.unit_currency_mismatch_rejected == true
  and .reconciliation.provenance_attached == true
  and .reconciliation.connector_contract_bound == true
  and .entitlement.gate_allowed == true
  and .entitlement.uses_recorded == true
  and .append_only.estimate_update_blocked == true
  and .append_only.reconciliation_update_blocked == true
  and .append_only.reconciliation_truncate_blocked == true
  and .audit_chain.valid == true
  and .audit_positions.estimate > 0
  and .audit_positions.reconciliation > .audit_positions.estimate
' "$REPORT" >/dev/null || fail "WU-14 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-14 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-14 COMPLETE"
