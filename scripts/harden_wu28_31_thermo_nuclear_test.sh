#!/usr/bin/env bash
# Cross-WU thermo-nuclear hardening acceptance (migration 0033).
# Evidence: hardening report on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/harden-wu28-31"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/thermo-nuclear-hardening-report.json"
PROBE_SQL="db/fixtures/harden_wu28_31_thermo_nuclear_probe.sql"
HARDEN_PROJECT_NAME="${HARDEN_WU28_31_COMPOSE_PROJECT_NAME:-market-mate-harden-wu28-31}"
COMPOSE=(docker compose --project-name "$HARDEN_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)
BACKEND_URL="${HARDEN_WU28_31_BACKEND_URL:-http://127.0.0.1:8080}"

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "HARDEN WU-28-31 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "HARDEN WU-28-31 PASS: $1"; }
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
      '{\"source\":\"harden-wu28-31-acceptance\",\"entitlement_version\":\"experiment-registry-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command curl
require_command docker
require_command jq
log "== Harden WU-28-31 thermo-nuclear test $(date -u +%FT%TZ) (project: $HARDEN_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30 market-mate-wu31 market-mate-wu32 market-mate-harden-wu28-31; do
  [[ "$sibling" == "$HARDEN_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior harden Compose state"
log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 || fail "Compose bring-up failed"
wait_for_healthy_services 300 || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

backend_ready=$(curl -fsS "$BACKEND_URL/readyz") || fail "backend /readyz is unavailable"
jq -e '.status == "ok" and .database == true and .migrations == true' <<<"$backend_ready" >/dev/null \
  || fail "backend /readyz is not migration-ready: $backend_ready"
pass "backend readiness confirms migration head"

migration_head=$("${PSQL[@]}" -c "SELECT coalesce(max(version), 0) FROM schema_migration;") \
  || fail "could not read the applied migration head"
[[ "$migration_head" == "33" ]] || fail "expected migration head 33, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 33;") \
  || fail "could not read migration 33 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 33 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 33 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/harden-wu28-31-thermo-nuclear-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the hardening probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/harden-wu28-31-thermo-nuclear-probe.sql \
  -c "SELECT result FROM harden_wu28_31_probe_result;" -c "ROLLBACK;") \
  || fail "WU-28-31 hardening probe failed: $probe_result"

for key in \
  empty_calendar_blocked short_calendar_blocked non_suffix_blocked \
  suffix_seal_recorded holm_uses_declared_family_size \
  result_bearing_null_p_blocked aborted_null_p_allowed \
  aborted_only_correction_blocked holm_successor_keeps_declared_size \
  family_change_successor_blocked family_omitted_successor_blocked \
  duplicate_predecessor_blocked \
  seal_audited correction_audited; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "empty and short EOD calendars fail closed; the sealed holdout is the calendar suffix"
pass "Holm m is the declared family size; result-bearing trials require a p_value"
pass "experimental lineage refuses a forked predecessor"

run_one=$(curl -fsS -X POST "$BACKEND_URL/tracer/run") \
  || fail "first tracer run failed"
run_two=$(curl -fsS -X POST "$BACKEND_URL/tracer/run") \
  || fail "second tracer run failed"
for run in "$run_one" "$run_two"; do
  jq -e '
    (.preregistration_id | length) == 36
    and (.evaluation_id | length) == 36
    and (.spec_digest | test("^[0-9a-f]{64}$"))
    and (.result_digest | test("^[0-9a-f]{64}$"))
  ' <<<"$run" >/dev/null \
    || fail "tracer run artifact is not well-formed: $run"
done
ordering_ok=$("${PSQL[@]}" -c "
  SELECT bool_and(p.receipt_time <= e.receipt_time)
  FROM evaluation_result e
  JOIN experiment_preregistration p ON p.registration_id = e.registration_id;
") || fail "preregistration/evaluation ordering query failed"
[[ "$ordering_ok" == "t" ]] || fail "an evaluation result was recorded before its preregistration"
pass "tracer snapshot and evaluation use clock_timestamp(); preregistration precedes every result"

record_payload=$(jq -c '{empty_calendar_blocked, short_calendar_blocked, non_suffix_blocked, suffix_seal_recorded, holm_uses_declared_family_size, result_bearing_null_p_blocked, aborted_null_p_allowed, aborted_only_correction_blocked, holm_successor_keeps_declared_size, family_change_successor_blocked, family_omitted_successor_blocked, duplicate_predecessor_blocked}' <<<"$probe_result")
guard_payload=$(jq -c '{seal_audited, correction_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "harden-wu28-31-record-$(date +%s)" "research.thermo_nuclear_hardening_proved" "$(jq -nc --argjson evidence "$record_payload" --arg tracer_ordering "$ordering_ok" '{probe: "harden_wu28_31_thermo_nuclear_probe", tracer_prereg_precedes_eval: ($tracer_ordering == "t"), evidence: $evidence}')") \
  || fail "audit append thermo_nuclear_hardening_proved failed"
chain_guard=$(append_audit_event "harden-wu28-31-guards-$(date +%s)" "research.thermo_nuclear_hardening_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "harden_wu28_31_thermo_nuclear_probe", evidence: $evidence}')") \
  || fail "audit append thermo_nuclear_hardening_guards_probed failed"
[[ "$chain_guard" -gt "$chain_record" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "hardening probes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson migration_head "$migration_head" \
  --arg migration_checksum "$migration_checksum" \
  --arg migration_schema_head "$migration_schema_head" \
  --arg migration_fingerprint "$migration_fingerprint" \
  --arg tracer_prereg_precedes_eval "$ordering_ok" \
  --argjson audit_position_record "$chain_record" \
  --argjson audit_position_guards "$chain_guard" \
  '{
    captured_at: $captured_at,
    migration: {
      head: $migration_head,
      expected_head: 33,
      version: 33,
      name: "cross_wu_thermo_nuclear_hardening",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    holdout: {
      empty_calendar_blocked: $probe.empty_calendar_blocked,
      short_calendar_blocked: $probe.short_calendar_blocked,
      non_suffix_blocked: $probe.non_suffix_blocked,
      suffix_seal_recorded: $probe.suffix_seal_recorded
    },
    multiplicity: {
      holm_uses_declared_family_size: $probe.holm_uses_declared_family_size,
      result_bearing_null_p_blocked: $probe.result_bearing_null_p_blocked,
      aborted_null_p_allowed: $probe.aborted_null_p_allowed,
      aborted_only_correction_blocked: $probe.aborted_only_correction_blocked,
      holm_successor_keeps_declared_size: $probe.holm_successor_keeps_declared_size,
      family_change_successor_blocked: $probe.family_change_successor_blocked,
      family_omitted_successor_blocked: $probe.family_omitted_successor_blocked
    },
    lineage: {
      duplicate_predecessor_blocked: $probe.duplicate_predecessor_blocked
    },
    tracer: {
      preregistration_precedes_evaluation: ($tracer_prereg_precedes_eval == "t")
    },
    append_only_and_fail_closed: {
      seal_audited: $probe.seal_audited,
      correction_audited: $probe.correction_audited
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write hardening evidence report"
jq -e '
  .migration.head == 33
  and .migration.expected_head == 33
  and .migration.name == "cross_wu_thermo_nuclear_hardening"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .holdout.empty_calendar_blocked == true
  and .holdout.short_calendar_blocked == true
  and .holdout.non_suffix_blocked == true
  and .holdout.suffix_seal_recorded == true
  and .multiplicity.holm_uses_declared_family_size == true
  and .multiplicity.result_bearing_null_p_blocked == true
  and .multiplicity.aborted_null_p_allowed == true
  and .multiplicity.holm_successor_keeps_declared_size == true
  and .multiplicity.family_change_successor_blocked == true
  and .multiplicity.family_omitted_successor_blocked == true
  and .lineage.duplicate_predecessor_blocked == true
  and .tracer.preregistration_precedes_evaluation == true
  and .audit_chain.valid == true
  and .audit_positions.guards > .audit_positions.record
' "$REPORT" >/dev/null || fail "hardening evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named hardening evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "HARDEN WU-28-31 COMPLETE"
