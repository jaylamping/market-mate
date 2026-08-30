#!/usr/bin/env bash
# WU-26 executable acceptance test — Indicator definition registry.
# Evidence: immutable versioned definitions, lifecycle retirement, and
# isolated mutation-probe report on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-26"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/indicator-registry-report.json"
PROBE_SQL="db/fixtures/wu26_indicator_registry_probe.sql"
WU26_PROJECT_NAME="${WU26_COMPOSE_PROJECT_NAME:-market-mate-wu26}"
COMPOSE=(docker compose --project-name "$WU26_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-26 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-26 PASS: $1"; }
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
      '{\"source\":\"wu26-acceptance\",\"entitlement_version\":\"coverage-policy-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq
log "== WU-26 Indicator definition registry test $(date -u +%FT%TZ) (project: $WU26_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23; do
  [[ "$sibling" == "$WU26_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-26 Compose state"
log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 || fail "Compose bring-up failed"
wait_for_healthy_services 300 || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

backend_ready=$(curl -fsS http://127.0.0.1:8080/readyz) || fail "backend /readyz is unavailable"
jq -e '.status == "ok" and .database == true and .migrations == true' <<<"$backend_ready" >/dev/null \
  || fail "backend /readyz is not migration-ready: $backend_ready"
pass "backend readiness confirms migration head"

migration_head=$("${PSQL[@]}" -c "SELECT coalesce(max(version), 0) FROM schema_migration;") \
  || fail "could not read the applied migration head"
[[ "$migration_head" == "25" ]] || fail "expected migration head 25, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 25;") \
  || fail "could not read migration 25 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 25 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 25 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu26-indicator-registry-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-26 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu26-indicator-registry-probe.sql \
  -c "SELECT result FROM wu26_probe_result;" -c "ROLLBACK;") \
  || fail "WU-26 Indicator registry probe failed: $probe_result"

for key in \
  core_v1_declared digest_content_addressed experimental_starts_experimental \
  semantic_change_creates_new_version successor_lineage_recorded \
  missing_golden_cases_blocked noncanonical_horizon_blocked \
  unregistered_source_blocked duplicate_version_blocked version_skip_blocked \
  wrong_successor_blocked experimental_to_declared_blocked \
  unknown_definition_lifecycle_blocked retirement_is_lifecycle_record \
  retired_never_revisible historical_evaluation_keeps_its_version \
  later_as_of_resolves_new_version retired_definition_still_resolvable_by_version \
  definition_update_blocked definition_delete_blocked \
  lifecycle_truncate_blocked appends_audited retirement_audited \
  current_view_latest_versions; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "immutable versioned definitions with explicit states pass"
pass "semantic-change versioning, successor lineage, and decision-time resolution pass"
pass "retirement lifecycle, illegal-transition, and point-in-time probes pass"
pass "append-only and invalid-input probes fail closed"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.indicator_definition_version', 'INSERT')
     AND NOT has_table_privilege('public', 'public.indicator_definition_lifecycle', 'INSERT')
     AND NOT has_function_privilege('public', 'append_indicator_definition_version(text,integer,text,jsonb,uuid,timestamptz,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'record_indicator_definition_lifecycle(uuid,text,text,text,jsonb)', 'EXECUTE');
") || fail "could not inspect public indicator registry write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public indicator registry write privileges were not revoked"
pass "public indicator registry writes are revoked; workflow guards remain the measured local boundary"

definition_payload=$(jq -c '{core_v1_declared, digest_content_addressed, experimental_starts_experimental, semantic_change_creates_new_version, successor_lineage_recorded, historical_evaluation_keeps_its_version, later_as_of_resolves_new_version, retired_definition_still_resolvable_by_version, current_view_latest_versions}' <<<"$probe_result")
gate_payload=$(jq -c '{missing_golden_cases_blocked, noncanonical_horizon_blocked, unregistered_source_blocked, duplicate_version_blocked, version_skip_blocked, wrong_successor_blocked, experimental_to_declared_blocked, unknown_definition_lifecycle_blocked, retirement_is_lifecycle_record, retired_never_revisible}' <<<"$probe_result")
guard_payload=$(jq -c '{definition_update_blocked, definition_delete_blocked, lifecycle_truncate_blocked, appends_audited, retirement_audited}' <<<"$probe_result")
chain_definition=$(append_audit_event "wu26-definitions-$(date +%s)" "research.indicator_definitions_proved" "$(jq -nc --argjson evidence "$definition_payload" '{probe: "wu26_indicator_registry_probe", evidence: $evidence}')")
chain_gate=$(append_audit_event "wu26-gates-$(date +%s)" "research.indicator_registry_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu26_indicator_registry_probe", evidence: $evidence}')")
chain_guard=$(append_audit_event "wu26-guards-$(date +%s)" "research.indicator_registry_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu26_indicator_registry_probe", evidence: $evidence}')")
[[ "$chain_gate" -gt "$chain_definition" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_definition -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "definition decisions and isolated guard probes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson migration_head "$migration_head" \
  --arg migration_checksum "$migration_checksum" \
  --arg migration_schema_head "$migration_schema_head" \
  --arg migration_fingerprint "$migration_fingerprint" \
  --arg public_write_revoked "$public_write_revoked" \
  --argjson audit_position_definitions "$chain_definition" \
  --argjson audit_position_gates "$chain_gate" \
  --argjson audit_position_guards "$chain_guard" \
  '{
    captured_at: $captured_at,
    migration: {
      head: $migration_head,
      expected_head: 25,
      version: 25,
      name: "indicator_registry",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    registry: {
      core_v1_declared: $probe.core_v1_declared,
      digest_content_addressed: $probe.digest_content_addressed,
      experimental_starts_experimental: $probe.experimental_starts_experimental,
      semantic_change_creates_new_version: $probe.semantic_change_creates_new_version,
      successor_lineage_recorded: $probe.successor_lineage_recorded,
      historical_evaluation_keeps_its_version: $probe.historical_evaluation_keeps_its_version,
      later_as_of_resolves_new_version: $probe.later_as_of_resolves_new_version,
      retired_definition_still_resolvable_by_version: $probe.retired_definition_still_resolvable_by_version,
      current_view_latest_versions: $probe.current_view_latest_versions
    },
    gates: {
      missing_golden_cases_blocked: $probe.missing_golden_cases_blocked,
      noncanonical_horizon_blocked: $probe.noncanonical_horizon_blocked,
      unregistered_source_blocked: $probe.unregistered_source_blocked,
      duplicate_version_blocked: $probe.duplicate_version_blocked,
      version_skip_blocked: $probe.version_skip_blocked,
      wrong_successor_blocked: $probe.wrong_successor_blocked,
      experimental_to_declared_blocked: $probe.experimental_to_declared_blocked,
      unknown_definition_lifecycle_blocked: $probe.unknown_definition_lifecycle_blocked,
      retirement_is_lifecycle_record: $probe.retirement_is_lifecycle_record,
      retired_never_revisible: $probe.retired_never_revisible
    },
    append_only_and_fail_closed: {
      definition_update_blocked: $probe.definition_update_blocked,
      definition_delete_blocked: $probe.definition_delete_blocked,
      lifecycle_truncate_blocked: $probe.lifecycle_truncate_blocked,
      appends_audited: $probe.appends_audited,
      retirement_audited: $probe.retirement_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {definitions: $audit_position_definitions, gates: $audit_position_gates, guards: $audit_position_guards}
  }' >"$REPORT" || fail "could not write WU-26 evidence report"
jq -e '
  .migration.head == 25
  and .migration.expected_head == 25
  and .migration.version == 25
  and .migration.name == "indicator_registry"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and (.migration.schema_head | length) > 0
  and (.migration.fingerprint | length) > 0
  and .registry.core_v1_declared == true
  and .registry.digest_content_addressed == true
  and .registry.experimental_starts_experimental == true
  and .registry.semantic_change_creates_new_version == true
  and .registry.successor_lineage_recorded == true
  and .registry.historical_evaluation_keeps_its_version == true
  and .registry.later_as_of_resolves_new_version == true
  and .registry.retired_definition_still_resolvable_by_version == true
  and .registry.current_view_latest_versions == true
  and .gates.missing_golden_cases_blocked == true
  and .gates.noncanonical_horizon_blocked == true
  and .gates.unregistered_source_blocked == true
  and .gates.duplicate_version_blocked == true
  and .gates.version_skip_blocked == true
  and .gates.wrong_successor_blocked == true
  and .gates.experimental_to_declared_blocked == true
  and .gates.unknown_definition_lifecycle_blocked == true
  and .gates.retirement_is_lifecycle_record == true
  and .gates.retired_never_revisible == true
  and .append_only_and_fail_closed.definition_update_blocked == true
  and .append_only_and_fail_closed.definition_delete_blocked == true
  and .append_only_and_fail_closed.lifecycle_truncate_blocked == true
  and .append_only_and_fail_closed.appends_audited == true
  and .append_only_and_fail_closed.retirement_audited == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.definitions
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-26 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-26 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-26 COMPLETE"
