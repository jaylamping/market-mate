#!/usr/bin/env bash
# WU-16 executable acceptance test — immutable snapshots and cycle manifests.
# Evidence: snapshot successor and manifest-index integrity report.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-16"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/snapshot-manifest-report.json"
PROBE_SQL="db/fixtures/wu16_snapshot_manifest_probe.sql"
WU16_PROJECT_NAME="${WU16_COMPOSE_PROJECT_NAME:-market-mate-wu16}"
COMPOSE=(docker compose --project-name "$WU16_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-16 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-16 PASS: $1"; }
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
      '{\"source\":\"wu16-acceptance\",\"entitlement_version\":\"snapshot-v1\"}'::jsonb,
      now(), 'local_research'
    );
  " || fail "audit append $event_type failed"
}

require_command docker
require_command jq
log "== WU-16 snapshot/manifest test $(date -u +%FT%TZ) (project: $WU16_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15; do
  [[ "$sibling" == "$WU16_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-16 Compose state"
log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 || fail "Compose bring-up failed"
wait_for_healthy_services 300 || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu16-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-16 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu16-probe.sql \
  -c "SELECT result FROM wu16_probe_result;" -c "ROLLBACK;") \
  || fail "WU-16 snapshot/manifest probe failed: $probe_result"

for key in \
  snapshot_successor_linked snapshot_correction_recorded snapshot_payload_digest_bound \
  manifest_indexes_expected_snapshots manifest_records_degraded_stale_state \
  manifest_superseding_delta_linked snapshot_update_blocked snapshot_revision_update_blocked manifest_update_blocked \
  manifest_entry_truncate_blocked; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "snapshot corrections create linked successors with digest-bound payloads"
pass "cycle manifest indexes expected snapshots, completion, evidence, and stale state"
pass "superseding manifest and entry deltas preserve correction lineage"
pass "snapshot, revision, and manifest mutation probes isolate append-only guards"

snapshot_payload=$(jq -c '{successor: .snapshot_successor_linked, correction: .snapshot_correction_recorded, digest: .snapshot_payload_digest_bound}' <<<"$probe_result")
manifest_payload=$(jq -c '{expected: .manifest_indexes_expected_snapshots, stale: .manifest_records_degraded_stale_state, delta: .manifest_superseding_delta_linked}' <<<"$probe_result")
chain_snapshot=$(append_audit_event "wu16-snapshot-$(date +%s)" "research.snapshot_successor_created" "$(jq -nc --argjson evidence "$snapshot_payload" '{probe: "wu16_snapshot_manifest_probe", evidence: $evidence}')")
chain_manifest=$(append_audit_event "wu16-manifest-$(date +%s)" "research.cycle_manifest_indexed" "$(jq -nc --argjson evidence "$manifest_payload" '{probe: "wu16_snapshot_manifest_probe", evidence: $evidence}')")
[[ "$chain_manifest" -gt "$chain_snapshot" ]] || fail "audit chain positions did not advance: $chain_snapshot -> $chain_manifest"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "snapshot and manifest outcomes are recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson audit_position_snapshot "$chain_snapshot" \
  --argjson audit_position_manifest "$chain_manifest" \
  '{
    captured_at: $captured_at,
    snapshots: {
      successor_linked: $probe.snapshot_successor_linked,
      correction_recorded: $probe.snapshot_correction_recorded,
      payload_digest_bound: $probe.snapshot_payload_digest_bound
    },
    manifest: {
      indexes_expected_snapshots: $probe.manifest_indexes_expected_snapshots,
      records_degraded_stale_state: $probe.manifest_records_degraded_stale_state,
      superseding_delta_linked: $probe.manifest_superseding_delta_linked
    },
    append_only: {
      snapshot_update_blocked: $probe.snapshot_update_blocked,
      snapshot_revision_update_blocked: $probe.snapshot_revision_update_blocked,
      manifest_update_blocked: $probe.manifest_update_blocked,
      manifest_entry_truncate_blocked: $probe.manifest_entry_truncate_blocked
    },
    audit_chain: $chain,
    audit_positions: {snapshot: $audit_position_snapshot, manifest: $audit_position_manifest}
  }' >"$REPORT" || fail "could not write WU-16 evidence report"
jq -e '
  .snapshots.successor_linked == true
  and .snapshots.correction_recorded == true
  and .snapshots.payload_digest_bound == true
  and .manifest.indexes_expected_snapshots == true
  and .manifest.records_degraded_stale_state == true
  and .manifest.superseding_delta_linked == true
  and .append_only.snapshot_update_blocked == true
  and .append_only.snapshot_revision_update_blocked == true
  and .append_only.manifest_update_blocked == true
  and .append_only.manifest_entry_truncate_blocked == true
  and .audit_chain.valid == true
  and .audit_positions.snapshot > 0
  and .audit_positions.manifest > .audit_positions.snapshot
' "$REPORT" >/dev/null || fail "WU-16 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] || fail "named WU-16 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-16 COMPLETE"
