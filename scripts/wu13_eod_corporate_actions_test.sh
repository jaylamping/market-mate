#!/usr/bin/env bash
# WU-13 executable acceptance test — licensed EOD and corporate actions.
# Evidence: ingestion lineage manifest and vendor-selection record.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-13"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/eod-corporate-actions-lineage-report.json"
PROBE_SQL="db/fixtures/wu13_eod_corporate_actions_probe.sql"
WU13_PROJECT_NAME="${WU13_COMPOSE_PROJECT_NAME:-market-mate-wu13}"
COMPOSE=(docker compose --project-name "$WU13_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-13 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-13 PASS: $1"; }
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
      '{\"source\":\"wu13-acceptance\",\"entitlement_version\":\"licensed-eod-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq
log "== WU-13 licensed EOD/corporate-actions test $(date -u +%FT%TZ) (project: $WU13_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"

for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12; do
  [[ "$sibling" == "$WU13_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-13 Compose state"
log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 || fail "Compose bring-up failed"
wait_for_healthy_services 300 || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu13-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-13 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu13-probe.sql \
  -c "SELECT result FROM wu13_probe_result;" -c "ROLLBACK;") \
  || fail "WU-13 connector probe failed: $probe_result"

for key in \
  vendor_selection_recorded daily_bar_ingested missing_observation_ingested \
  revision_appended point_in_time_preserved corporate_action_ingested \
  corporate_action_revision_appended corporate_action_terms_revised \
  entitlement_gate_allowed allowed_use_receipts_recorded denied_use_has_no_observation \
  denial_recorded price_source_lineage_attached corporate_action_source_lineage_attached \
  price_update_blocked corporate_action_update_blocked price_truncate_blocked; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "selected vendor evidence records license, entitlement, and cost criteria"
pass "daily OHLCV preserves point-in-time revisions, including missing observations"
pass "corporate-action terms revisions append through the existing lifecycle workflow"
pass "entitlement gate records denial and prevents unauthorized EOD evidence"
pass "EOD and corporate-action mutation probes isolate append-only guards"

ingestion_payload=$(jq -nc \
  --argjson bar "$(jq -c '{complete: .daily_bar_ingested, missing: .missing_observation_ingested, revised: .revision_appended, point_in_time: .point_in_time_preserved}' <<<"$probe_result")" \
  --argjson action "$(jq -c '{ingested: .corporate_action_ingested, revised: .corporate_action_revision_appended, terms: .corporate_action_terms_revised}' <<<"$probe_result")" \
  '{probe: "wu13_eod_corporate_actions_probe", eod: $bar, corporate_action: $action}')
chain_ingestion=$(append_audit_event "wu13-ingestion-$(date +%s)" "eod.ingestion_completed" "$ingestion_payload")
revision_payload=$(jq -nc \
  --argjson revisions "$(jq -c '{eod: .revision_appended, corporate_action: .corporate_action_revision_appended, point_in_time: .point_in_time_preserved}' <<<"$probe_result")" \
  '{probe: "wu13_eod_corporate_actions_probe", revisions: $revisions}')
chain_revision=$(append_audit_event "wu13-revisions-$(date +%s)" "corporate_action.revision_appended" "$revision_payload")
[[ "$chain_revision" -gt "$chain_ingestion" ]] || fail "audit chain positions did not advance: $chain_ingestion -> $chain_revision"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "EOD and corporate-action outcomes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson audit_position_ingestion "$chain_ingestion" \
  --argjson audit_position_revision "$chain_revision" \
  '{
    captured_at: $captured_at,
    vendor_selection: {recorded: $probe.vendor_selection_recorded},
    ingestion: {
      daily_bar_ingested: $probe.daily_bar_ingested,
      missing_observation_ingested: $probe.missing_observation_ingested,
      revision_appended: $probe.revision_appended,
      point_in_time_preserved: $probe.point_in_time_preserved,
      corporate_action_ingested: $probe.corporate_action_ingested,
      corporate_action_revision_appended: $probe.corporate_action_revision_appended,
      corporate_action_terms_revised: $probe.corporate_action_terms_revised,
      entitlement_gate_allowed: $probe.entitlement_gate_allowed,
      allowed_use_receipts_recorded: $probe.allowed_use_receipts_recorded
    },
    entitlement_gate: {
      denial_recorded: $probe.denial_recorded,
      denied_use_has_no_observation: $probe.denied_use_has_no_observation
    },
    provenance: {
      price_source_lineage_attached: $probe.price_source_lineage_attached,
      corporate_action_source_lineage_attached: $probe.corporate_action_source_lineage_attached
    },
    append_only: {
      price_update_blocked: $probe.price_update_blocked,
      corporate_action_update_blocked: $probe.corporate_action_update_blocked,
      price_truncate_blocked: $probe.price_truncate_blocked
    },
    audit_chain: $chain,
    audit_positions: {ingestion: $audit_position_ingestion, revision: $audit_position_revision}
  }' >"$REPORT" || fail "could not write WU-13 evidence report"
jq -e '
  .vendor_selection.recorded == true
  and .ingestion.daily_bar_ingested == true
  and .ingestion.missing_observation_ingested == true
  and .ingestion.revision_appended == true
  and .ingestion.point_in_time_preserved == true
  and .ingestion.corporate_action_ingested == true
  and .ingestion.corporate_action_revision_appended == true
  and .ingestion.corporate_action_terms_revised == true
  and .ingestion.entitlement_gate_allowed == true
  and .ingestion.allowed_use_receipts_recorded == true
  and .entitlement_gate.denial_recorded == true
  and .entitlement_gate.denied_use_has_no_observation == true
  and .provenance.price_source_lineage_attached == true
  and .provenance.corporate_action_source_lineage_attached == true
  and .append_only.price_update_blocked == true
  and .append_only.corporate_action_update_blocked == true
  and .append_only.price_truncate_blocked == true
  and .audit_chain.valid == true
  and .audit_positions.ingestion > 0
  and .audit_positions.revision > .audit_positions.ingestion
' "$REPORT" >/dev/null || fail "WU-13 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-13 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-13 COMPLETE"
