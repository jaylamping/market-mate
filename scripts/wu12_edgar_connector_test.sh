#!/usr/bin/env bash
# WU-12 executable acceptance test — EDGAR connector.
# Evidence: ingested corpus and lineage manifest written to evidence/wu-12/.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-12"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/edgar-ingestion-lineage-report.json"
PROBE_SQL="db/fixtures/wu12_edgar_connector_probe.sql"
WU12_PROJECT_NAME="${WU12_COMPOSE_PROJECT_NAME:-market-mate-wu12}"
COMPOSE=(docker compose --project-name "$WU12_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() {
  printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"
}

fail() {
  log "WU-12 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}

pass() {
  log "WU-12 PASS: $1"
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
      '{\"source\":\"wu12-acceptance\",\"entitlement_version\":\"sec-edgar-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq

log "== WU-12 EDGAR connector test $(date -u +%FT%TZ) (project: $WU12_PROJECT_NAME) =="

"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose configuration is invalid"

for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11; do
  if [[ "$sibling" == "$WU12_PROJECT_NAME" ]]; then continue; fi
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove prior WU-12 Compose state"

log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose bring-up failed"

wait_for_healthy_services 300 \
  || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

# Run the connector probe in one rolled-back transaction so the corpus remains
# disposable while real entitlement, identity, and content-boundary paths run.
"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu12-probe.sql \
  >>"$BRING_UP_LOG" 2>&1 || fail "could not copy the EDGAR probe into the postgres container"
probe_result=$("${PSQL[@]}" \
  -c "BEGIN;" \
  -f /tmp/wu12-probe.sql \
  -c "SELECT result FROM wu12_probe_result;" \
  -c "ROLLBACK;") \
  || fail "EDGAR connector probe failed: $probe_result"

for key in \
  filing_ingested xbrl_actual_ingested same_concept_multi_fact_supported filing_receipt_time_preserved connector_contract_bound \
  actual_receipt_time_preserved certified_mapping_linked actual_identity_linked \
  entitlement_gate_allowed entitlement_use_recorded filing_raw_content_verbatim \
  xbrl_raw_content_verbatim content_marked_untrusted filing_source_lineage_attached \
  actual_source_lineage_attached filing_entitlement_version_attached \
  actual_entitlement_version_attached direct_update_blocked direct_delete_blocked \
  non_certified_mapping_rejected; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "EDGAR filing and XBRL actual preserve receipt timing and certified identity mapping"
pass "EDGAR and XBRL content is stored verbatim, digest-bound, and marked untrusted"
pass "entitlement-gated use carries source/version provenance and rejects uncertified mappings"
pass "EDGAR evidence rejects direct mutation"

# Material ingestion outcomes are represented on the verified append-only audit chain.
ingestion_payload=$(jq -nc \
  --argjson filing "$(jq -c '{ingested: .filing_ingested, receipt_time: .filing_receipt_time_preserved, identity: .certified_mapping_linked}' <<<"$probe_result")" \
  --argjson actual "$(jq -c '{ingested: .xbrl_actual_ingested, receipt_time: .actual_receipt_time_preserved, identity: .actual_identity_linked}' <<<"$probe_result")" \
  '{probe: "wu12_edgar_connector_probe", filing: $filing, xbrl_actual: $actual}')
chain_ingestion=$(append_audit_event "wu12-ingestion-$(date +%s)" \
  "edgar.ingestion_completed" "$ingestion_payload")
content_payload=$(jq -nc \
  --argjson content "$(jq -c '{filing_verbatim: .filing_raw_content_verbatim, xbrl_verbatim: .xbrl_raw_content_verbatim, untrusted: .content_marked_untrusted}' <<<"$probe_result")" \
  '{probe: "wu12_edgar_connector_probe", content: $content}')
chain_content=$(append_audit_event "wu12-content-$(date +%s)" \
  "edgar.untrusted_content_stored" "$content_payload")
[[ "$chain_content" -gt "$chain_ingestion" ]] \
  || fail "audit chain positions did not advance: $chain_ingestion -> $chain_content"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null \
  || fail "audit chain does not verify: $chain_ok"
pass "EDGAR ingestion and untrusted-content handling recorded on the verified audit chain"

# Assemble and validate the named evidence artifact.
jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson audit_position_ingestion "$chain_ingestion" \
  --argjson audit_position_content "$chain_content" \
  '{
    captured_at: $captured_at,
    ingestion: {
      filing_ingested: $probe.filing_ingested,
      xbrl_actual_ingested: $probe.xbrl_actual_ingested,
      same_concept_multi_fact_supported: $probe.same_concept_multi_fact_supported,
      filing_receipt_time_preserved: $probe.filing_receipt_time_preserved,
      actual_receipt_time_preserved: $probe.actual_receipt_time_preserved,
      connector_contract_bound: $probe.connector_contract_bound,
      certified_mapping_linked: $probe.certified_mapping_linked,
      actual_identity_linked: $probe.actual_identity_linked,
      entitlement_gate_allowed: $probe.entitlement_gate_allowed,
      entitlement_use_recorded: $probe.entitlement_use_recorded
    },
    untrusted_content: {
      filing_raw_content_verbatim: $probe.filing_raw_content_verbatim,
      xbrl_raw_content_verbatim: $probe.xbrl_raw_content_verbatim,
      content_marked_untrusted: $probe.content_marked_untrusted,
      direct_update_blocked: $probe.direct_update_blocked,
      direct_delete_blocked: $probe.direct_delete_blocked,
      non_certified_mapping_rejected: $probe.non_certified_mapping_rejected
    },
    provenance: {
      filing_source_lineage_attached: $probe.filing_source_lineage_attached,
      actual_source_lineage_attached: $probe.actual_source_lineage_attached,
      filing_entitlement_version_attached: $probe.filing_entitlement_version_attached,
      actual_entitlement_version_attached: $probe.actual_entitlement_version_attached
    },
    audit_chain: $chain,
    audit_positions: {
      ingestion: $audit_position_ingestion,
      content: $audit_position_content
    }
  }' >"$REPORT" \
  || fail "could not write EDGAR ingestion lineage report"

jq -e '
  .ingestion.filing_ingested == true
  and .ingestion.xbrl_actual_ingested == true
  and .ingestion.same_concept_multi_fact_supported == true
  and .ingestion.filing_receipt_time_preserved == true
  and .ingestion.actual_receipt_time_preserved == true
  and .ingestion.connector_contract_bound == true
  and .ingestion.certified_mapping_linked == true
  and .ingestion.actual_identity_linked == true
  and .ingestion.entitlement_gate_allowed == true
  and .ingestion.entitlement_use_recorded == true
  and .untrusted_content.filing_raw_content_verbatim == true
  and .untrusted_content.xbrl_raw_content_verbatim == true
  and .untrusted_content.content_marked_untrusted == true
  and .untrusted_content.direct_update_blocked == true
  and .untrusted_content.direct_delete_blocked == true
  and .untrusted_content.non_certified_mapping_rejected == true
  and .provenance.filing_source_lineage_attached == true
  and .provenance.actual_source_lineage_attached == true
  and .provenance.filing_entitlement_version_attached == true
  and .provenance.actual_entitlement_version_attached == true
  and .audit_chain.valid == true
  and .audit_positions.ingestion > 0
  and .audit_positions.content > 0
' "$REPORT" >/dev/null \
  || fail "EDGAR ingestion lineage report does not satisfy the WU-12 evidence schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] \
  || fail "named WU-12 evidence is not retrievable"

pass "valid evidence is retrievable at $REPORT"
log "WU-12 COMPLETE"
