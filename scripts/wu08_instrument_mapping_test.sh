#!/usr/bin/env bash
# WU-08 executable acceptance test — instrument mapping workflow.
# Evidence: mapping state-machine report written to evidence/wu-08/.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-08"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/mapping-state-machine-report.json"
PROBE_SQL="db/fixtures/wu08_mapping_workflow_probe.sql"
WU08_PROJECT_NAME="${WU08_COMPOSE_PROJECT_NAME:-market-mate-wu08}"
COMPOSE=(docker compose --project-name "$WU08_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() {
  printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"
}

fail() {
  log "WU-08 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}

pass() {
  log "WU-08 PASS: $1"
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
      '{\"source\":\"wu08-acceptance\",\"entitlement_version\":\"local-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq

log "== WU-08 instrument mapping test $(date -u +%FT%TZ) (project: $WU08_PROJECT_NAME) =="

"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose configuration is invalid"

for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09; do
  if [[ "$sibling" == "$WU08_PROJECT_NAME" ]]; then continue; fi
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove prior WU-08 Compose state"

log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose bring-up failed"

wait_for_healthy_services 300 \
  || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

# 1. Run the whole lifecycle workflow inside one rolled-back transaction.
"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu08-probe.sql \
  >>"$BRING_UP_LOG" 2>&1 || fail "could not copy the workflow probe into the postgres container"
workflow_result=$("${PSQL[@]}" \
  -c "BEGIN;" \
  -f /tmp/wu08-probe.sql \
  -c "SELECT result FROM wu08_probe_result;" \
  -c "ROLLBACK;") \
  || fail "instrument-mapping workflow probe failed: $workflow_result"
[[ "$(jq -r '.proposed_mappings_created' <<<"$workflow_result")" == "true" ]] \
  || fail "mappings were not created: $workflow_result"
[[ "$(jq -r '.proposed_to_certified_blocked' <<<"$workflow_result")" == "true" ]] \
  || fail "proposed -> certified was not blocked: $workflow_result"
pass "state machine refuses proposed -> certified; corroboration path reaches certified"
[[ "$(jq -r '.corroboration_path_to_certified' <<<"$workflow_result")" == "true" ]] \
  || fail "the corroboration path failed: $workflow_result"
[[ "$(jq -r '.certified_mapping_in_view' <<<"$workflow_result")" == "true" ]] \
  || fail "the certified view did not expose the certified mapping: $workflow_result"
[[ "$(jq -r '.direct_update_blocked' <<<"$workflow_result")" == "true" ]] \
  || fail "direct lifecycle UPDATE was not blocked: $workflow_result"
pass "certified mapping is consumable via the certified view only; direct writes are blocked"

# 2. Conflicting provider mappings fail closed and are resolvable only by a
#    recorded suspend, never by a silent pick.
[[ "$(jq -r '.conflicting_certification_blocked' <<<"$workflow_result")" == "true" ]] \
  || fail "conflicting certification was not refused: $workflow_result"
[[ "$(jq -r '.resolution_via_suspend_then_certify' <<<"$workflow_result")" == "true" ]] \
  || fail "suspend-then-certify resolution did not yield the right certified mapping: $workflow_result"
[[ "$(jq -r '.suspended_mapping_not_consumable' <<<"$workflow_result")" == "true" ]] \
  || fail "a suspended mapping remained consumable: $workflow_result"
pass "conflicting certification fails closed; resolution requires a recorded suspend"

# 3. Retired is terminal and rows are never deleted.
[[ "$(jq -r '.retired_is_terminal' <<<"$workflow_result")" == "true" ]] \
  || fail "retired -> certified was not blocked: $workflow_result"
[[ "$(jq -r '.delete_blocked' <<<"$workflow_result")" == "true" ]] \
  || fail "DELETE was not blocked: $workflow_result"
[[ "$(jq -r '.mismatched_object_kind_refused' <<<"$workflow_result")" == "true" ]] \
  || fail "mismatched object_kind was not refused: $workflow_result"
[[ "$(jq -r '.transition_history_count_matches_moves' <<<"$workflow_result")" == "true" ]] \
  || fail "transition history does not match the performed moves: $workflow_result"
pass "retired is terminal, deletes blocked, mismatched targets refused, history complete"

# 4. Material actions land on the append-only audit chain.
workflow_payload=$(jq -nc \
  --argjson transitions "$(jq '.transitions_recorded' <<<"$workflow_result")" \
  '{probe: "wu08_mapping_workflow_probe", transitions_recorded: $transitions, conflicting_certification_blocked: true}')
chain_before=$(append_audit_event "wu08-workflow-$(date +%s)" \
  "instrument.mapping_workflow_completed" \
  "$workflow_payload")
conflict_payload='{"native_identifier":"WU08","provider":"vendor-wu08","decision":"refused","reason":"conflicting certified mapping"}'
chain_after=$(append_audit_event "wu08-conflict-$(date +%s)" \
  "instrument.mapping_conflict_denied" \
  "$conflict_payload")
[[ "$chain_after" -gt "$chain_before" ]] \
  || fail "audit chain positions did not advance: $chain_before -> $chain_after"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null \
  || fail "audit chain does not verify: $chain_ok"
pass "workflow and conflict denial recorded on the verified audit chain"

# 5. Assemble and validate the evidence report.
jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson workflow "$workflow_result" \
  --argjson chain "$chain_ok" \
  --argjson audit_position_workflow "$chain_before" \
  --argjson audit_position_conflict "$chain_after" \
  '{
    captured_at: $captured_at,
    lifecycle: {
      proposed_to_certified_blocked: $workflow.proposed_to_certified_blocked,
      corroboration_path_to_certified: $workflow.corroboration_path_to_certified,
      certified_view_only: ($workflow.certified_mapping_in_view and $workflow.direct_update_blocked and $workflow.suspended_mapping_not_consumable)
    },
    conflict_handling: {
      conflicting_certification_blocked: $workflow.conflicting_certification_blocked,
      resolution_via_suspend_then_certify: $workflow.resolution_via_suspend_then_certify
    },
    integrity: {
      retired_is_terminal: $workflow.retired_is_terminal,
      delete_blocked: $workflow.delete_blocked,
      mismatched_object_kind_refused: $workflow.mismatched_object_kind_refused,
      transition_history_count_matches_moves: $workflow.transition_history_count_matches_moves,
      transitions_recorded: $workflow.transitions_recorded
    },
    audit_chain: $chain,
    audit_positions: {
      workflow_completed: $audit_position_workflow,
      conflict_denied: $audit_position_conflict
    }
  }' >"$REPORT" \
  || fail "could not write mapping state-machine report"

jq -e '
  .lifecycle.proposed_to_certified_blocked == true
  and .lifecycle.corroboration_path_to_certified == true
  and .lifecycle.certified_view_only == true
  and .conflict_handling.conflicting_certification_blocked == true
  and .conflict_handling.resolution_via_suspend_then_certify == true
  and .integrity.retired_is_terminal == true
  and .integrity.delete_blocked == true
  and .integrity.mismatched_object_kind_refused == true
  and .integrity.transition_history_count_matches_moves == true
  and .integrity.transitions_recorded == 6
  and .audit_chain.valid == true
  and .audit_positions.workflow_completed > 0
  and .audit_positions.conflict_denied > 0
' "$REPORT" >/dev/null \
  || fail "mapping state-machine report does not satisfy the WU-08 evidence schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] \
  || fail "named WU-08 evidence is not retrievable"

pass "valid evidence is retrievable at $REPORT"
log "WU-08 COMPLETE"
