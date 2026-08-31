#!/usr/bin/env bash
# WU-35 executable acceptance test — EIS estimator and cluster counting.
# Evidence: estimator test vectors on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-35"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/estimator-test-vectors.json"
PROBE_SQL="db/fixtures/wu35_eis_estimator_probe.sql"
WU35_PROJECT_NAME="${WU35_COMPOSE_PROJECT_NAME:-market-mate-wu35}"
COMPOSE=(docker compose --project-name "$WU35_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-35 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-35 PASS: $1"; }
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
      '{\"source\":\"wu35-acceptance\",\"entitlement_version\":\"eis-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-35 EIS estimator test $(date -u +%FT%TZ) (project: $WU35_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30 market-mate-wu31 market-mate-wu32 market-mate-wu33 market-mate-wu34 market-mate-wu35 market-mate-wu36 market-mate-harden-wu28-31; do
  [[ "$sibling" == "$WU35_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-35 Compose state"
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
[[ "$migration_head" == "37" ]] || fail "expected migration head 37, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 37;") \
  || fail "could not read migration 37 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 37 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 37 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu35-eis-estimator-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-35 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu35-eis-estimator-probe.sql \
  -c "SELECT result FROM wu35_probe_result;" -c "ROLLBACK;") \
  || fail "WU-35 EIS estimator probe failed: $probe_result"

for key in \
  independent_not_collapsed double_run_digest_match floor_is_lower_of_clusters_and_eis \
  overlapping_holdings_one_cluster legs_do_not_inflate retries_do_not_inflate \
  issuer_event_one_cluster common_shock_one_cluster dependent_exit_one_cluster \
  autocorr_reduces_eis negative_autocorr_does_not_inflate walk_forward_trades_mapped \
  recorded_estimate record_is_idempotent credential_key_blocked paper_key_blocked \
  empty_observations_blocked unknown_run_blocked direct_insert_blocked \
  estimate_update_blocked estimate_delete_blocked estimate_truncate_blocked \
  estimate_audited; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "dependent activity collapses to one cluster; legs and retries do not inflate"
pass "EIS is autocorrelation-adjusted; floor is min(cluster count, EIS)"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.eis_estimate', 'INSERT')
     AND NOT has_function_privilege('public', 'record_eis_estimate(jsonb,uuid,jsonb)', 'EXECUTE');
") || fail "could not inspect public EIS write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public EIS write privileges were not revoked"
pass "public EIS writes are revoked; workflow guards remain the measured local boundary"

record_payload=$(jq -c '{independent_not_collapsed, overlapping_holdings_one_cluster, legs_do_not_inflate, retries_do_not_inflate, autocorr_reduces_eis, floor_is_lower_of_clusters_and_eis, recorded_estimate, record_is_idempotent}' <<<"$probe_result")
gate_payload=$(jq -c '{issuer_event_one_cluster, common_shock_one_cluster, dependent_exit_one_cluster, negative_autocorr_does_not_inflate, walk_forward_trades_mapped, credential_key_blocked, paper_key_blocked, empty_observations_blocked}' <<<"$probe_result")
guard_payload=$(jq -c '{unknown_run_blocked, direct_insert_blocked, estimate_update_blocked, estimate_delete_blocked, estimate_truncate_blocked, estimate_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "wu35-record-$(date +%s)" "research.eis_vectors_proved" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu35_eis_estimator_probe", evidence: $evidence}')") \
  || fail "audit append eis_vectors_proved failed"
chain_gate=$(append_audit_event "wu35-gates-$(date +%s)" "research.eis_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu35_eis_estimator_probe", evidence: $evidence}')") \
  || fail "audit append eis_gates_proved failed"
chain_guard=$(append_audit_event "wu35-guards-$(date +%s)" "research.eis_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu35_eis_estimator_probe", evidence: $evidence}')") \
  || fail "audit append eis_guards_probed failed"
[[ "$chain_gate" -gt "$chain_record" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "estimator vectors, gates, and isolated guard probes are recorded on the verified audit chain"

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
      expected_head: 37,
      version: 37,
      name: "eis_estimator",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    vectors: {
      independent_not_collapsed: $probe.independent_not_collapsed,
      overlapping_holdings_one_cluster: $probe.overlapping_holdings_one_cluster,
      legs_do_not_inflate: $probe.legs_do_not_inflate,
      retries_do_not_inflate: $probe.retries_do_not_inflate,
      issuer_event_one_cluster: $probe.issuer_event_one_cluster,
      common_shock_one_cluster: $probe.common_shock_one_cluster,
      dependent_exit_one_cluster: $probe.dependent_exit_one_cluster,
      autocorr_reduces_eis: $probe.autocorr_reduces_eis,
      negative_autocorr_does_not_inflate: $probe.negative_autocorr_does_not_inflate,
      floor_is_lower_of_clusters_and_eis: $probe.floor_is_lower_of_clusters_and_eis,
      walk_forward_trades_mapped: $probe.walk_forward_trades_mapped,
      double_run_digest_match: $probe.double_run_digest_match,
      recorded_estimate: $probe.recorded_estimate,
      record_is_idempotent: $probe.record_is_idempotent
    },
    gates: {
      credential_key_blocked: $probe.credential_key_blocked,
      paper_key_blocked: $probe.paper_key_blocked,
      empty_observations_blocked: $probe.empty_observations_blocked,
      unknown_run_blocked: $probe.unknown_run_blocked
    },
    append_only_and_fail_closed: {
      direct_insert_blocked: $probe.direct_insert_blocked,
      estimate_update_blocked: $probe.estimate_update_blocked,
      estimate_delete_blocked: $probe.estimate_delete_blocked,
      estimate_truncate_blocked: $probe.estimate_truncate_blocked,
      estimate_audited: $probe.estimate_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-35 evidence report"
jq -e '
  .migration.head == 37
  and .migration.expected_head == 37
  and .migration.name == "eis_estimator"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .vectors.independent_not_collapsed == true
  and .vectors.legs_do_not_inflate == true
  and .vectors.retries_do_not_inflate == true
  and .vectors.autocorr_reduces_eis == true
  and .vectors.floor_is_lower_of_clusters_and_eis == true
  and .vectors.record_is_idempotent == true
  and .gates.paper_key_blocked == true
  and .append_only_and_fail_closed.direct_insert_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-35 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-35 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-35 COMPLETE"
