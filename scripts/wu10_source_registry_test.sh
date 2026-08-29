#!/usr/bin/env bash
# WU-10 executable acceptance test — Source Registry and Data Contract schema.
# Evidence: registry + contract report written to evidence/wu-10/.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-10"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/source-registry-contract-report.json"
PROBE_SQL="db/fixtures/wu10_source_registry_probe.sql"
WU10_PROJECT_NAME="${WU10_COMPOSE_PROJECT_NAME:-market-mate-wu10}"
COMPOSE=(docker compose --project-name "$WU10_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() {
  printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"
}

fail() {
  log "WU-10 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}

pass() {
  log "WU-10 PASS: $1"
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
      '{\"source\":\"wu10-acceptance\",\"entitlement_version\":\"local-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq

log "== WU-10 Source Registry and Data Contract test $(date -u +%FT%TZ) (project: $WU10_PROJECT_NAME) =="

"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose configuration is invalid"

for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09; do
  if [[ "$sibling" == "$WU10_PROJECT_NAME" ]]; then continue; fi
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove prior WU-10 Compose state"

log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose bring-up failed"

wait_for_healthy_services 300 \
  || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

# Run the schema probe in one rolled-back transaction so the evidence covers
# real constraints without leaving fixture rows in the shared database.
"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu10-probe.sql \
  >>"$BRING_UP_LOG" 2>&1 || fail "could not copy the registry probe into the postgres container"
probe_result=$("${PSQL[@]}" \
  -c "BEGIN;" \
  -f /tmp/wu10-probe.sql \
  -c "SELECT result FROM wu10_probe_result;" \
  -c "ROLLBACK;") \
  || fail "Source Registry/Data Contract probe failed: $probe_result"

for key in \
  source_registered required_registry_terms source_versions_point_in_time \
  overlapping_source_version_rejected contract_registered \
  contract_versions_effectively_dated consumed_fields_bound_to_version \
  connector_fields_match_contract_version mismatched_field_version_rejected \
  unregistered_source_rejected versioned_records_append_only \
  contract_source_range_rejected overlapping_contract_version_rejected \
  source_version_mismatch_rejected connector_binding_version_mismatch_rejected \
  source_connector_update_blocked source_connector_delete_blocked; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "registry entries record license, permitted use, lineage rules, observation states, and correction semantics"
pass "source registry versions are effective-dated and overlapping versions are rejected"
pass "versioned registry and contract authorities reject update, delete, and truncate mutation"
pass "contract versions stay within their registered source version effective range"
pass "overlapping contract versions and registered-but-mismatched source versions are rejected"
pass "a connector cannot bind a field through a mismatched contract-version composite key"
pass "every consumed connector field is bound to its exact effective contract version"
pass "a connector cannot bind a field from a different contract version"
pass "an otherwise-valid connector cannot reference an unregistered source"

# Material registry and contract bindings are represented on the verified
# append-only audit chain, matching the WU-03 evidence boundary.
registry_payload=$(jq -nc \
  --argjson source_key "$(jq -c '.source_key' <<<"$probe_result")" \
  --argjson source_versions "$(jq -c '.source_versions' <<<"$probe_result")" \
  '{probe: "wu10_source_registry_probe", source_key: $source_key, source_versions: $source_versions}')
chain_registry=$(append_audit_event "wu10-registry-$(date +%s)" \
  "source_registry.versioned" "$registry_payload")
contract_payload=$(jq -nc \
  --argjson fields "$(jq -c '.bound_field_keys' <<<"$probe_result")" \
  '{probe: "wu10_source_registry_probe", bound_field_keys: $fields, effective_dating: true}')
chain_contract=$(append_audit_event "wu10-contract-$(date +%s)" \
  "data_contract.fields_bound" "$contract_payload")
[[ "$chain_contract" -gt "$chain_registry" ]] \
  || fail "audit chain positions did not advance: $chain_registry -> $chain_contract"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null \
  || fail "audit chain does not verify: $chain_ok"
pass "registry admission and contract field binding recorded on the verified audit chain"

# Assemble and validate the named evidence artifact.
jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson audit_position_registry "$chain_registry" \
  --argjson audit_position_contract "$chain_contract" \
  '{
    captured_at: $captured_at,
    source_registry: {
      source_key: $probe.source_key,
      required_terms_recorded: $probe.required_registry_terms,
      versions_point_in_time: $probe.source_versions_point_in_time,
      overlapping_version_rejected: $probe.overlapping_source_version_rejected,
      unregistered_source_rejected: $probe.unregistered_source_rejected,
      versioned_records_append_only: $probe.versioned_records_append_only
    },
    data_contract: {
      contract_registered: $probe.contract_registered,
      versions_effectively_dated: $probe.contract_versions_effectively_dated,
      consumed_fields_bound_to_version: $probe.consumed_fields_bound_to_version,
      connector_fields_match_contract_version: $probe.connector_fields_match_contract_version,
      mismatched_field_version_rejected: $probe.mismatched_field_version_rejected,
      contract_source_range_rejected: $probe.contract_source_range_rejected,
      overlapping_version_rejected: $probe.overlapping_contract_version_rejected,
      source_version_mismatch_rejected: $probe.source_version_mismatch_rejected,
      connector_binding_version_mismatch_rejected: $probe.connector_binding_version_mismatch_rejected,
      bound_field_keys: $probe.bound_field_keys
    },
    source_connector: {
      update_blocked: $probe.source_connector_update_blocked,
      delete_blocked: $probe.source_connector_delete_blocked
    },
    audit_chain: $chain,
    audit_positions: {
      source_registry: $audit_position_registry,
      data_contract: $audit_position_contract
    }
  }' >"$REPORT" \
  || fail "could not write Source Registry/Data Contract report"

jq -e '
  .source_registry.required_terms_recorded == true
  and .source_registry.versions_point_in_time == true
  and .source_registry.overlapping_version_rejected == true
  and .source_registry.unregistered_source_rejected == true
  and .source_registry.versioned_records_append_only == true
  and .data_contract.contract_registered == true
  and .data_contract.versions_effectively_dated == true
  and .data_contract.consumed_fields_bound_to_version == true
  and .data_contract.connector_fields_match_contract_version == true
  and .data_contract.mismatched_field_version_rejected == true
  and .data_contract.contract_source_range_rejected == true
  and .data_contract.overlapping_version_rejected == true
  and .data_contract.source_version_mismatch_rejected == true
  and .data_contract.connector_binding_version_mismatch_rejected == true
  and .source_connector.update_blocked == true
  and .source_connector.delete_blocked == true
  and .audit_chain.valid == true
  and .audit_positions.source_registry > 0
  and .audit_positions.data_contract > 0
' "$REPORT" >/dev/null \
  || fail "Source Registry/Data Contract report does not satisfy the WU-10 evidence schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] \
  || fail "named WU-10 evidence is not retrievable"

pass "valid evidence is retrievable at $REPORT"
log "WU-10 COMPLETE"
