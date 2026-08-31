#!/usr/bin/env bash
# WU-31 executable acceptance test — Evidence budgets and multiplicity.
# Evidence: budget/correction test report on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-31"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/budget-correction-report.json"
PROBE_SQL="db/fixtures/wu31_evidence_budgets_probe.sql"
WU31_PROJECT_NAME="${WU31_COMPOSE_PROJECT_NAME:-market-mate-wu31}"
COMPOSE=(docker compose --project-name "$WU31_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-31 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-31 PASS: $1"; }
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
      '{\"source\":\"wu31-acceptance\",\"entitlement_version\":\"experiment-registry-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-31 Evidence budgets and multiplicity test $(date -u +%FT%TZ) (project: $WU31_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30 market-mate-wu31 market-mate-wu32; do
  [[ "$sibling" == "$WU31_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-31 Compose state"
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
[[ "$migration_head" == "32" ]] || fail "expected migration head 32, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 32;") \
  || fail "could not read migration 32 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 32 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 32 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu31-evidence-budgets-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-31 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu31-evidence-budgets-probe.sql \
  -c "SELECT result FROM wu31_probe_result;" -c "ROLLBACK;") \
  || fail "WU-31 Evidence budgets probe failed: $probe_result"

for key in \
  holm_default_vector bonferroni_vector default_plan_is_holm \
  preregistered_bonferroni uncorrected_method_blocked conflicting_methods_blocked \
  holm_applies_by_default exhausted_budget_refused refusal_recorded \
  preregistered_bonferroni_applies missing_family_blocked missing_budget_blocked \
  invalid_p_value_blocked empty_correction_blocked \
  direct_trial_insert_blocked trial_update_blocked refusal_delete_blocked \
  trial_truncate_blocked refusal_truncate_blocked correction_truncate_blocked \
  trials_audited refusal_audited correction_audited; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "Holm applies across family members by default"
pass "a different correction applies only when preregistered"
pass "exhausted testing budget refuses further trials and records the refusal"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.experiment_trial', 'INSERT')
     AND NOT has_table_privilege('public', 'public.experiment_trial_refusal', 'INSERT')
     AND NOT has_table_privilege('public', 'public.experiment_family_correction', 'INSERT')
     AND NOT has_function_privilege('public', 'record_experiment_trial(uuid,text,numeric,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'compute_experiment_family_correction(text,jsonb)', 'EXECUTE');
") || fail "could not inspect public experiment budget write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public experiment budget write privileges were not revoked"
pass "public experiment budget writes are revoked; workflow guards remain the measured local boundary"

record_payload=$(jq -c '{holm_default_vector, bonferroni_vector, default_plan_is_holm, holm_applies_by_default, preregistered_bonferroni_applies, exhausted_budget_refused, refusal_recorded}' <<<"$probe_result")
gate_payload=$(jq -c '{uncorrected_method_blocked, conflicting_methods_blocked, missing_family_blocked, missing_budget_blocked, invalid_p_value_blocked, empty_correction_blocked}' <<<"$probe_result")
guard_payload=$(jq -c '{direct_trial_insert_blocked, trial_update_blocked, refusal_delete_blocked, trial_truncate_blocked, refusal_truncate_blocked, correction_truncate_blocked, trials_audited, refusal_audited, correction_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "wu31-record-$(date +%s)" "research.experiment_budget_record_proved" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu31_evidence_budgets_probe", evidence: $evidence}')") \
  || fail "audit append experiment_budget_record_proved failed"
chain_gate=$(append_audit_event "wu31-gates-$(date +%s)" "research.experiment_budget_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu31_evidence_budgets_probe", evidence: $evidence}')") \
  || fail "audit append experiment_budget_gates_proved failed"
chain_guard=$(append_audit_event "wu31-guards-$(date +%s)" "research.experiment_budget_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu31_evidence_budgets_probe", evidence: $evidence}')") \
  || fail "audit append experiment_budget_guards_probed failed"
[[ "$chain_gate" -gt "$chain_record" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "correction, budget, and isolated guard probes are recorded on the verified audit chain"

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
      expected_head: 32,
      version: 32,
      name: "evidence_budgets_multiplicity",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    correction: {
      holm_default_vector: $probe.holm_default_vector,
      bonferroni_vector: $probe.bonferroni_vector,
      default_plan_is_holm: $probe.default_plan_is_holm,
      holm_applies_by_default: $probe.holm_applies_by_default,
      preregistered_bonferroni_applies: $probe.preregistered_bonferroni_applies
    },
    budget: {
      exhausted_budget_refused: $probe.exhausted_budget_refused,
      refusal_recorded: $probe.refusal_recorded
    },
    gates: {
      uncorrected_method_blocked: $probe.uncorrected_method_blocked,
      conflicting_methods_blocked: $probe.conflicting_methods_blocked,
      missing_family_blocked: $probe.missing_family_blocked,
      missing_budget_blocked: $probe.missing_budget_blocked,
      invalid_p_value_blocked: $probe.invalid_p_value_blocked,
      empty_correction_blocked: $probe.empty_correction_blocked
    },
    append_only_and_fail_closed: {
      direct_trial_insert_blocked: $probe.direct_trial_insert_blocked,
      trial_update_blocked: $probe.trial_update_blocked,
      refusal_delete_blocked: $probe.refusal_delete_blocked,
      trial_truncate_blocked: $probe.trial_truncate_blocked,
      refusal_truncate_blocked: $probe.refusal_truncate_blocked,
      correction_truncate_blocked: $probe.correction_truncate_blocked,
      trials_audited: $probe.trials_audited,
      refusal_audited: $probe.refusal_audited,
      correction_audited: $probe.correction_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-31 evidence report"
jq -e '
  .migration.head == 32
  and .migration.expected_head == 32
  and .migration.name == "evidence_budgets_multiplicity"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .correction.holm_applies_by_default == true
  and .correction.preregistered_bonferroni_applies == true
  and .budget.exhausted_budget_refused == true
  and .budget.refusal_recorded == true
  and .gates.conflicting_methods_blocked == true
  and .append_only_and_fail_closed.direct_trial_insert_blocked == true
  and .append_only_and_fail_closed.trial_truncate_blocked == true
  and .append_only_and_fail_closed.refusal_truncate_blocked == true
  and .append_only_and_fail_closed.correction_truncate_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-31 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-31 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-31 COMPLETE"
