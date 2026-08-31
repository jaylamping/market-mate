#!/usr/bin/env bash
# WU-32 executable acceptance test — Strategy Version artifact and registration.
# Evidence: strategy registry with fixture strategy on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-32"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/strategy-registry-report.json"
PROBE_SQL="db/fixtures/wu32_strategy_version_probe.sql"
WU32_PROJECT_NAME="${WU32_COMPOSE_PROJECT_NAME:-market-mate-wu32}"
COMPOSE=(docker compose --project-name "$WU32_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-32 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-32 PASS: $1"; }
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
      \$a\$${event_id}\$a\$, \$a\$${event_type}\$a\$, now(),
      \$a\$${payload}\$a\$::jsonb,
      '{\"source\":\"wu32-acceptance\",\"entitlement_version\":\"strategy-registry-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-32 Strategy Version artifact and registration test $(date -u +%FT%TZ) (project: $WU32_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30 market-mate-wu31 market-mate-wu32 market-mate-wu33 market-mate-harden-wu28-31; do
  [[ "$sibling" == "$WU32_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-32 Compose state"
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
[[ "$migration_head" == "34" ]] || fail "expected migration head 34, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 34;") \
  || fail "could not read migration 34 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 34 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 34 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu32-strategy-version-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-32 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu32-strategy-version-probe.sql \
  -c "SELECT result FROM wu32_probe_result;" -c "ROLLBACK;") \
  || fail "WU-32 Strategy Version probe failed: $probe_result"

for key in \
  registered_with_preregistration_lineage content_addressed fixture_strategy_recorded \
  idempotent_same_artifact mutation_without_successor_blocked mutation_creates_new_version \
  stale_successor_blocked cross_strategy_successor_blocked unknown_registration_blocked \
  incomplete_dsl_version_blocked incomplete_rules_blocked missing_cash_comparator_blocked \
  non_stock_universe_blocked sentiment_universe_blocked wasm_engine_blocked \
  incomplete_engine_binding_blocked live_authority_blocked paper_authority_blocked \
  spec_key_mismatch_blocked omitted_sentiment_blocked strategy_eligible_claim_blocked \
  glossary_live_eligible_blocked unknown_spec_key_blocked \
  direct_insert_blocked version_update_blocked \
  version_delete_blocked version_truncate_blocked appends_audited original_never_mutates; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "Strategy Version is content-addressed, immutable, and bound to its preregistration"
pass "a mutation appends a new frozen version; the original never mutates"
pass "Paper/Live authority claims, WASM bindings, and append-only probes fail closed"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.strategy_version', 'INSERT')
     AND NOT has_function_privilege('public', 'register_strategy_version(text,jsonb,jsonb,uuid,uuid,jsonb)', 'EXECUTE');
") || fail "could not inspect public strategy version write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public strategy version write privileges were not revoked"
pass "public strategy version writes are revoked; workflow guards remain the measured local boundary"

record_payload=$(jq -c '{registered_with_preregistration_lineage, content_addressed, fixture_strategy_recorded, idempotent_same_artifact, mutation_creates_new_version, original_never_mutates}' <<<"$probe_result")
gate_payload=$(jq -c '{mutation_without_successor_blocked, stale_successor_blocked, cross_strategy_successor_blocked, unknown_registration_blocked, incomplete_dsl_version_blocked, incomplete_rules_blocked, missing_cash_comparator_blocked, non_stock_universe_blocked, sentiment_universe_blocked, wasm_engine_blocked, incomplete_engine_binding_blocked, live_authority_blocked, paper_authority_blocked, spec_key_mismatch_blocked, omitted_sentiment_blocked, strategy_eligible_claim_blocked, glossary_live_eligible_blocked, unknown_spec_key_blocked}' <<<"$probe_result")
guard_payload=$(jq -c '{direct_insert_blocked, version_update_blocked, version_delete_blocked, version_truncate_blocked, appends_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "wu32-record-$(date +%s)" "research.strategy_version_record_proved" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu32_strategy_version_probe", evidence: $evidence}')") \
  || fail "audit append strategy_version_record_proved failed"
chain_gate=$(append_audit_event "wu32-gates-$(date +%s)" "research.strategy_version_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu32_strategy_version_probe", evidence: $evidence}')") \
  || fail "audit append strategy_version_gates_proved failed"
chain_guard=$(append_audit_event "wu32-guards-$(date +%s)" "research.strategy_version_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu32_strategy_version_probe", evidence: $evidence}')") \
  || fail "audit append strategy_version_guards_probed failed"
[[ "$chain_gate" -gt "$chain_record" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "fixture strategy, gates, and isolated guard probes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson migration_head "$migration_head" \
  --arg migration_checksum "$migration_checksum" \
  --arg migration_schema_head "$migration_schema_head" \
  --arg migration_fingerprint "$migration_fingerprint" \
  --arg public_write_revoked "$public_write_revoked" \
  --argjson audit_position_record "$chain_record" \
  --argjson audit_position_gates "$chain_gate" \
  --argjson audit_position_guards "$chain_guard" \
  '{
    captured_at: $captured_at,
    migration: {
      head: $migration_head,
      expected_head: 34,
      version: 34,
      name: "strategy_version_registry",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    registry: {
      registered_with_preregistration_lineage: $probe.registered_with_preregistration_lineage,
      content_addressed: $probe.content_addressed,
      fixture_strategy_recorded: $probe.fixture_strategy_recorded,
      idempotent_same_artifact: $probe.idempotent_same_artifact,
      mutation_creates_new_version: $probe.mutation_creates_new_version,
      original_never_mutates: $probe.original_never_mutates
    },
    gates: {
      mutation_without_successor_blocked: $probe.mutation_without_successor_blocked,
      stale_successor_blocked: $probe.stale_successor_blocked,
      cross_strategy_successor_blocked: $probe.cross_strategy_successor_blocked,
      unknown_registration_blocked: $probe.unknown_registration_blocked,
      incomplete_dsl_version_blocked: $probe.incomplete_dsl_version_blocked,
      incomplete_rules_blocked: $probe.incomplete_rules_blocked,
      missing_cash_comparator_blocked: $probe.missing_cash_comparator_blocked,
      non_stock_universe_blocked: $probe.non_stock_universe_blocked,
      sentiment_universe_blocked: $probe.sentiment_universe_blocked,
      wasm_engine_blocked: $probe.wasm_engine_blocked,
      incomplete_engine_binding_blocked: $probe.incomplete_engine_binding_blocked,
      live_authority_blocked: $probe.live_authority_blocked,
      paper_authority_blocked: $probe.paper_authority_blocked,
      spec_key_mismatch_blocked: $probe.spec_key_mismatch_blocked,
      omitted_sentiment_blocked: $probe.omitted_sentiment_blocked,
      strategy_eligible_claim_blocked: $probe.strategy_eligible_claim_blocked,
      glossary_live_eligible_blocked: $probe.glossary_live_eligible_blocked,
      unknown_spec_key_blocked: $probe.unknown_spec_key_blocked
    },
    append_only_and_fail_closed: {
      direct_insert_blocked: $probe.direct_insert_blocked,
      version_update_blocked: $probe.version_update_blocked,
      version_delete_blocked: $probe.version_delete_blocked,
      version_truncate_blocked: $probe.version_truncate_blocked,
      appends_audited: $probe.appends_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-32 evidence report"
jq -e '
  .migration.head == 34
  and .migration.expected_head == 34
  and .migration.name == "strategy_version_registry"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .registry.registered_with_preregistration_lineage == true
  and .registry.content_addressed == true
  and .registry.fixture_strategy_recorded == true
  and .registry.mutation_creates_new_version == true
  and .registry.original_never_mutates == true
  and .gates.live_authority_blocked == true
  and .gates.strategy_eligible_claim_blocked == true
  and .gates.unknown_spec_key_blocked == true
  and .gates.wasm_engine_blocked == true
  and .append_only_and_fail_closed.direct_insert_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-32 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-32 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-32 COMPLETE"
