#!/usr/bin/env bash
# WU-24 executable acceptance test — Coverage Fitness scoring and first
# Coverage Universe admission. Evidence: first Coverage Universe version
# plus replay artifact on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-24"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/coverage-universe-report.json"
PROBE_SQL="db/fixtures/wu24_coverage_fitness_probe.sql"
WU24_PROJECT_NAME="${WU24_COMPOSE_PROJECT_NAME:-market-mate-wu24}"
COMPOSE=(docker compose --project-name "$WU24_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-24 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-24 PASS: $1"; }
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
      '{\"source\":\"wu24-acceptance\",\"entitlement_version\":\"coverage-policy-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
log "== WU-24 Coverage Fitness and first admission test $(date -u +%FT%TZ) (project: $WU24_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28; do
  [[ "$sibling" == "$WU24_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-24 Compose state"
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
[[ "$migration_head" == "26" ]] || fail "expected migration head 26, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 26;") \
  || fail "could not read migration 26 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 26 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 26 and schema identity are recorded"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu24-coverage-fitness-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-24 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu24-coverage-fitness-probe.sql \
  -c "SELECT result FROM wu24_probe_result;" -c "ROLLBACK;") \
  || fail "WU-24 Coverage Fitness probe failed: $probe_result"

for key in \
  fitness_run_complete fitness_counts_consistent fitness_digest_valid \
  twins_equal_fitness twins_ignore_returns \
  experimental_excluded_from_observability core_definition_bound \
  missing_gics_below_floor late_gics_invisible_at_run_as_of late_gics_visible_after_receipt \
  otc_scored_not_admitted_enhanced_gates \
  universe_complete admitted_count_is_40 all_admitted_research_candidates \
  admitted_stock_eligible obligations_active \
  tech_admitted_at_ceiling tech_excess_rejected_sector_ceiling others_admitted \
  quality_floor_never_admitted \
  deterministic_score_replay_matches deterministic_seed_replay_matches \
  duplicate_fitness_blocked duplicate_seed_blocked \
  unapproved_policy_seed_blocked empty_pool_fails_closed future_as_of_blocked \
  invalid_gics_blocked direct_gics_insert_blocked direct_fitness_insert_blocked \
  fitness_update_blocked universe_delete_blocked membership_truncate_blocked \
  fitness_audited seed_audited predictive_fields_absent; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "fitness scoring, nonpredictive ranking, and quality-floor gates pass"
pass "first-seed admits 40 Research Candidates with obligations and bound Core definitions"
pass "sector ceiling, enhanced-risk fail-closed, and point-in-time GICS probes pass"
pass "deterministic replay, duplicate-run, and fail-closed probes pass"
pass "append-only and invalid-input probes fail closed"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.issuer_gics_classification', 'INSERT')
     AND NOT has_table_privilege('public', 'public.coverage_fitness_run', 'INSERT')
     AND NOT has_table_privilege('public', 'public.coverage_fitness_score', 'INSERT')
     AND NOT has_table_privilege('public', 'public.coverage_universe_version', 'INSERT')
     AND NOT has_table_privilege('public', 'public.coverage_universe_membership', 'INSERT')
     AND NOT has_function_privilege('public', 'append_issuer_gics_classification(uuid,text,timestamptz,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'run_coverage_fitness_score(uuid,uuid,timestamptz,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('public', 'run_coverage_universe_first_seed(uuid,text,integer,jsonb)', 'EXECUTE');
") || fail "could not inspect public coverage-fitness write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public coverage-fitness write privileges were not revoked"
pass "public coverage-fitness writes are revoked; workflow guards remain the measured local boundary"

score_payload=$(jq -c '{fitness_run_complete, fitness_counts_consistent, fitness_digest_valid, twins_equal_fitness, twins_ignore_returns, experimental_excluded_from_observability, core_definition_bound, missing_gics_below_floor, late_gics_invisible_at_run_as_of, late_gics_visible_after_receipt, predictive_fields_absent}' <<<"$probe_result")
admission_payload=$(jq -c '{otc_scored_not_admitted_enhanced_gates, universe_complete, admitted_count_is_40, all_admitted_research_candidates, admitted_stock_eligible, obligations_active, tech_admitted_at_ceiling, tech_excess_rejected_sector_ceiling, others_admitted, quality_floor_never_admitted}' <<<"$probe_result")
replay_payload=$(jq -c '{deterministic_score_replay_matches, deterministic_seed_replay_matches, duplicate_fitness_blocked, duplicate_seed_blocked, unapproved_policy_seed_blocked, empty_pool_fails_closed, future_as_of_blocked}' <<<"$probe_result")
guard_payload=$(jq -c '{invalid_gics_blocked, direct_gics_insert_blocked, direct_fitness_insert_blocked, fitness_update_blocked, universe_delete_blocked, membership_truncate_blocked, fitness_audited, seed_audited}' <<<"$probe_result")
chain_score=$(append_audit_event "wu24-fitness-$(date +%s)" "research.coverage_fitness_proved" "$(jq -nc --argjson evidence "$score_payload" '{probe: "wu24_coverage_fitness_probe", evidence: $evidence}')") \
  || fail "audit append coverage_fitness_proved failed"
chain_admission=$(append_audit_event "wu24-admission-$(date +%s)" "research.coverage_universe_first_seed_proved" "$(jq -nc --argjson evidence "$admission_payload" '{probe: "wu24_coverage_fitness_probe", evidence: $evidence}')") \
  || fail "audit append coverage_universe_first_seed_proved failed"
chain_replay=$(append_audit_event "wu24-replay-$(date +%s)" "research.coverage_fitness_replay_proved" "$(jq -nc --argjson evidence "$replay_payload" '{probe: "wu24_coverage_fitness_probe", evidence: $evidence}')") \
  || fail "audit append coverage_fitness_replay_proved failed"
chain_guard=$(append_audit_event "wu24-guards-$(date +%s)" "research.coverage_fitness_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu24_coverage_fitness_probe", evidence: $evidence}')") \
  || fail "audit append coverage_fitness_guards_probed failed"
[[ "$chain_admission" -gt "$chain_score" && "$chain_replay" -gt "$chain_admission" && "$chain_guard" -gt "$chain_replay" ]] \
  || fail "audit chain positions did not advance: $chain_score -> $chain_admission -> $chain_replay -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "scoring, first-seed, replay, and isolated guard probes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson migration_head "$migration_head" \
  --arg migration_checksum "$migration_checksum" \
  --arg migration_schema_head "$migration_schema_head" \
  --arg migration_fingerprint "$migration_fingerprint" \
  --arg public_write_revoked "$public_write_revoked" \
  --argjson audit_position_score "$chain_score" \
  --argjson audit_position_admission "$chain_admission" \
  --argjson audit_position_replay "$chain_replay" \
  --argjson audit_position_guards "$chain_guard" \
  '{
    captured_at: $captured_at,
    migration: {
      head: $migration_head,
      expected_head: 26,
      version: 26,
      name: "coverage_fitness_admission",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    scoring: {
      fitness_run_complete: $probe.fitness_run_complete,
      fitness_counts_consistent: $probe.fitness_counts_consistent,
      fitness_digest_valid: $probe.fitness_digest_valid,
      twins_equal_fitness: $probe.twins_equal_fitness,
      twins_ignore_returns: $probe.twins_ignore_returns,
      experimental_excluded_from_observability: $probe.experimental_excluded_from_observability,
      core_definition_bound: $probe.core_definition_bound,
      missing_gics_below_floor: $probe.missing_gics_below_floor,
      late_gics_invisible_at_run_as_of: $probe.late_gics_invisible_at_run_as_of,
      late_gics_visible_after_receipt: $probe.late_gics_visible_after_receipt,
      predictive_fields_absent: $probe.predictive_fields_absent
    },
    first_coverage_universe: {
      otc_scored_not_admitted_enhanced_gates: $probe.otc_scored_not_admitted_enhanced_gates,
      universe_complete: $probe.universe_complete,
      admitted_count_is_40: $probe.admitted_count_is_40,
      all_admitted_research_candidates: $probe.all_admitted_research_candidates,
      admitted_stock_eligible: $probe.admitted_stock_eligible,
      obligations_active: $probe.obligations_active,
      tech_admitted_at_ceiling: $probe.tech_admitted_at_ceiling,
      tech_excess_rejected_sector_ceiling: $probe.tech_excess_rejected_sector_ceiling,
      others_admitted: $probe.others_admitted,
      quality_floor_never_admitted: $probe.quality_floor_never_admitted
    },
    replay_and_fail_closed: {
      deterministic_score_replay_matches: $probe.deterministic_score_replay_matches,
      deterministic_seed_replay_matches: $probe.deterministic_seed_replay_matches,
      duplicate_fitness_blocked: $probe.duplicate_fitness_blocked,
      duplicate_seed_blocked: $probe.duplicate_seed_blocked,
      unapproved_policy_seed_blocked: $probe.unapproved_policy_seed_blocked,
      empty_pool_fails_closed: $probe.empty_pool_fails_closed,
      future_as_of_blocked: $probe.future_as_of_blocked
    },
    append_only_and_fail_closed: {
      invalid_gics_blocked: $probe.invalid_gics_blocked,
      direct_gics_insert_blocked: $probe.direct_gics_insert_blocked,
      direct_fitness_insert_blocked: $probe.direct_fitness_insert_blocked,
      fitness_update_blocked: $probe.fitness_update_blocked,
      universe_delete_blocked: $probe.universe_delete_blocked,
      membership_truncate_blocked: $probe.membership_truncate_blocked,
      fitness_audited: $probe.fitness_audited,
      seed_audited: $probe.seed_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      score: $audit_position_score,
      admission: $audit_position_admission,
      replay: $audit_position_replay,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-24 evidence report"
jq -e '
  .migration.head == 26
  and .migration.expected_head == 26
  and .migration.version == 26
  and .migration.name == "coverage_fitness_admission"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and (.migration.schema_head | length) > 0
  and (.migration.fingerprint | length) > 0
  and .scoring.fitness_run_complete == true
  and .scoring.fitness_counts_consistent == true
  and .scoring.fitness_digest_valid == true
  and .scoring.twins_equal_fitness == true
  and .scoring.twins_ignore_returns == true
  and .scoring.experimental_excluded_from_observability == true
  and .scoring.core_definition_bound == true
  and .scoring.missing_gics_below_floor == true
  and .scoring.late_gics_invisible_at_run_as_of == true
  and .scoring.late_gics_visible_after_receipt == true
  and .scoring.predictive_fields_absent == true
  and .first_coverage_universe.otc_scored_not_admitted_enhanced_gates == true
  and .first_coverage_universe.universe_complete == true
  and .first_coverage_universe.admitted_count_is_40 == true
  and .first_coverage_universe.all_admitted_research_candidates == true
  and .first_coverage_universe.admitted_stock_eligible == true
  and .first_coverage_universe.obligations_active == true
  and .first_coverage_universe.tech_admitted_at_ceiling == true
  and .first_coverage_universe.tech_excess_rejected_sector_ceiling == true
  and .first_coverage_universe.others_admitted == true
  and .first_coverage_universe.quality_floor_never_admitted == true
  and .replay_and_fail_closed.deterministic_score_replay_matches == true
  and .replay_and_fail_closed.deterministic_seed_replay_matches == true
  and .replay_and_fail_closed.duplicate_fitness_blocked == true
  and .replay_and_fail_closed.duplicate_seed_blocked == true
  and .replay_and_fail_closed.unapproved_policy_seed_blocked == true
  and .replay_and_fail_closed.empty_pool_fails_closed == true
  and .replay_and_fail_closed.future_as_of_blocked == true
  and .append_only_and_fail_closed.invalid_gics_blocked == true
  and .append_only_and_fail_closed.direct_gics_insert_blocked == true
  and .append_only_and_fail_closed.direct_fitness_insert_blocked == true
  and .append_only_and_fail_closed.fitness_update_blocked == true
  and .append_only_and_fail_closed.universe_delete_blocked == true
  and .append_only_and_fail_closed.membership_truncate_blocked == true
  and .append_only_and_fail_closed.fitness_audited == true
  and .append_only_and_fail_closed.seed_audited == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.admission > .audit_positions.score
  and .audit_positions.replay > .audit_positions.admission
  and .audit_positions.guards > .audit_positions.replay
' "$REPORT" >/dev/null || fail "WU-24 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-24 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-24 COMPLETE"
