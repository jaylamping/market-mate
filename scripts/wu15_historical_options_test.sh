#!/usr/bin/env bash
# WU-15 executable acceptance test — historical options-chain snapshots.
# Evidence: chain snapshot store, deliverable lineage, and real-time refusal.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-15"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/options-chain-lineage-report.json"
PROBE_SQL="db/fixtures/wu15_historical_options_probe.sql"
WU15_PROJECT_NAME="${WU15_COMPOSE_PROJECT_NAME:-market-mate-wu15}"
COMPOSE=(docker compose --project-name "$WU15_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-15 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-15 PASS: $1"; }
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
      '{\"source\":\"wu15-acceptance\",\"entitlement_version\":\"historical-options-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq
log "== WU-15 historical options test $(date -u +%FT%TZ) (project: $WU15_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14; do
  [[ "$sibling" == "$WU15_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-15 Compose state"
log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 || fail "Compose bring-up failed"
wait_for_healthy_services 300 || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu15-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-15 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu15-probe.sql \
  -c "SELECT result FROM wu15_probe_result;" -c "ROLLBACK;") \
  || fail "WU-15 connector probe failed: $probe_result"

for key in \
  snapshot_dates_preserved historical_mode_only point_in_time_provenance_preserved \
  certified_mapping_attached contracts_mapped_to_snapshots deliverable_semantics_attached \
  entitlement_gate_allowed historical_use_receipts_recorded snapshot_source_lineage_attached \
  contract_source_lineage_attached realtime_rejected snapshot_update_blocked \
  deliverable_update_blocked contract_truncate_blocked; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "representative snapshots preserve historical point-in-time timing and certified identity"
pass "contracts link immutable Option Deliverable Version semantics"
pass "historical entitlement is recorded and real-time entitlement is refused"
pass "options snapshot and deliverable mutation probes isolate append-only guards"

snapshot_payload=$(jq -c '{dates: .snapshot_dates_preserved, historical_only: .historical_mode_only, point_in_time: .point_in_time_provenance_preserved, mapping: .certified_mapping_attached}' <<<"$probe_result")
contract_payload=$(jq -c '{mapped: .contracts_mapped_to_snapshots, deliverable: .deliverable_semantics_attached, realtime_rejected: .realtime_rejected}' <<<"$probe_result")
chain_snapshot=$(append_audit_event "wu15-snapshot-$(date +%s)" "options.snapshot_ingested" "$(jq -nc --argjson evidence "$snapshot_payload" '{probe: "wu15_historical_options_probe", evidence: $evidence}')")
chain_contract=$(append_audit_event "wu15-contract-$(date +%s)" "options.contract_mapped" "$(jq -nc --argjson evidence "$contract_payload" '{probe: "wu15_historical_options_probe", evidence: $evidence}')")
[[ "$chain_contract" -gt "$chain_snapshot" ]] || fail "audit chain positions did not advance: $chain_snapshot -> $chain_contract"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "options-chain outcomes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson audit_position_snapshot "$chain_snapshot" \
  --argjson audit_position_contract "$chain_contract" \
  '{
    captured_at: $captured_at,
    snapshots: {
      dates_preserved: $probe.snapshot_dates_preserved,
      historical_mode_only: $probe.historical_mode_only,
      point_in_time_provenance_preserved: $probe.point_in_time_provenance_preserved,
      certified_mapping_attached: $probe.certified_mapping_attached,
      source_lineage_attached: $probe.snapshot_source_lineage_attached
    },
    contracts: {
      mapped_to_snapshots: $probe.contracts_mapped_to_snapshots,
      deliverable_semantics_attached: $probe.deliverable_semantics_attached,
      source_lineage_attached: $probe.contract_source_lineage_attached
    },
    entitlement: {
      gate_allowed: $probe.entitlement_gate_allowed,
      historical_use_receipts_recorded: $probe.historical_use_receipts_recorded,
      realtime_rejected: $probe.realtime_rejected
    },
    append_only: {
      snapshot_update_blocked: $probe.snapshot_update_blocked,
      deliverable_update_blocked: $probe.deliverable_update_blocked,
      contract_truncate_blocked: $probe.contract_truncate_blocked
    },
    audit_chain: $chain,
    audit_positions: {snapshot: $audit_position_snapshot, contract: $audit_position_contract}
  }' >"$REPORT" || fail "could not write WU-15 evidence report"
jq -e '
  .snapshots.dates_preserved == true
  and .snapshots.historical_mode_only == true
  and .snapshots.point_in_time_provenance_preserved == true
  and .snapshots.certified_mapping_attached == true
  and .snapshots.source_lineage_attached == true
  and .contracts.mapped_to_snapshots == true
  and .contracts.deliverable_semantics_attached == true
  and .contracts.source_lineage_attached == true
  and .entitlement.gate_allowed == true
  and .entitlement.historical_use_receipts_recorded == true
  and .entitlement.realtime_rejected == true
  and .append_only.snapshot_update_blocked == true
  and .append_only.deliverable_update_blocked == true
  and .append_only.contract_truncate_blocked == true
  and .audit_chain.valid == true
  and .audit_positions.snapshot > 0
  and .audit_positions.contract > .audit_positions.snapshot
' "$REPORT" >/dev/null || fail "WU-15 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-15 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-15 COMPLETE"
