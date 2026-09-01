#!/usr/bin/env bash
# WU-46 executable acceptance test — display-only stage-1 dashboard surfaces.
# Evidence: empty and populated surface walkthrough screenshots.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-46"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/stage1-surface-walkthrough.json"
EMPTY_HTML="$EVIDENCE_DIR/stage1-surfaces-empty.html"
POPULATED_HTML="$EVIDENCE_DIR/stage1-surfaces-populated.html"
EMPTY_PNG="$EVIDENCE_DIR/stage1-surfaces-empty.png"
POPULATED_PNG="$EVIDENCE_DIR/stage1-surfaces-populated.png"
REFUSAL_LOG="$EVIDENCE_DIR/dashboard-config-refusals.log"
PROBE_SQL="db/fixtures/wu46_stage1_surfaces_probe.sql"
WU46_PROJECT_NAME="${WU46_COMPOSE_PROJECT_NAME:-market-mate-wu46}"
PROJECT_OFFSET="${WU46_PORT_OFFSET:-460}"
export MARKET_MATE_FRONTEND_PORT=$((3000 + PROJECT_OFFSET))
export MARKET_MATE_POSTGRES_PORT=$((5432 + PROJECT_OFFSET))
export MARKET_MATE_BACKEND_PORT=$((8080 + PROJECT_OFFSET))
export MARKET_MATE_CUSTODY_PORT=$((8081 + PROJECT_OFFSET))
COMPOSE=(docker compose --project-name "$WU46_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)
BACKEND_URL="${WU46_BACKEND_URL:-http://127.0.0.1:${MARKET_MATE_BACKEND_PORT}}"
FRONTEND_URL="${WU46_FRONTEND_URL:-http://127.0.0.1:${MARKET_MATE_FRONTEND_PORT}}"
loopback_only=false
public_exposure_refused=false
authority_refused=false

mkdir -p "$EVIDENCE_DIR"
: >"$BRING_UP_LOG"
: >"$REFUSAL_LOG"
rm -f "$REPORT" "$EMPTY_HTML" "$POPULATED_HTML" "$EMPTY_PNG" "$POPULATED_PNG"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-46 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-46 PASS: $1"; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"; }
cleanup() { "${COMPOSE[@]}" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true; }
trap cleanup EXIT

wait_for_healthy_services() {
  local attempts="$1" healthy_count attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    healthy_count=$("${COMPOSE[@]}" ps --format json 2>/dev/null \
      | jq -s '[.[] | select(.Health == "healthy") | .Service] | unique | length' 2>/dev/null)
    if [[ "$healthy_count" == "4" ]]; then return 0; fi
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
      '{\"source\":\"wu46-acceptance\",\"entitlement_version\":\"stage1-surfaces-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

screenshot_url() {
  local url="$1" dest="$2"
  local chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  [[ -x "$chrome" ]] || fail "Google Chrome is required for screenshot evidence"
  "$chrome" --headless --disable-gpu --hide-scrollbars --window-size=1440,1000 \
    --screenshot="$dest" "$url" >>"$BRING_UP_LOG" 2>&1 \
    || fail "could not capture screenshot: $url"
  [[ -s "$dest" ]] || fail "screenshot evidence is empty: $dest"
}

run_committed_fixture() {
  local source="$1" container_name="$2" result_table="$3"
  "${COMPOSE[@]}" cp "$source" "postgres:/tmp/$container_name" >>"$BRING_UP_LOG" 2>&1 \
    || fail "could not copy fixture $source"
  "${PSQL[@]}" -f "/tmp/$container_name" -c "SELECT result FROM $result_table;" \
    >>"$BRING_UP_LOG" || fail "fixture failed: $source"
}

assert_refusal() {
  local variable="$1" output status
  set +e
  output=$("${COMPOSE[@]}" run --rm --no-deps -e "$variable=1" frontend 2>&1)
  status=$?
  set -e
  printf '%s\n' "$output" >>"$REFUSAL_LOG"
  [[ "$status" -ne 0 ]] || fail "$variable did not refuse dashboard startup"
  grep -q "config refused: $variable is set" <<<"$output" \
    || grep -q "unsupported dashboard configuration $variable" <<<"$output" \
    || fail "$variable refusal was not explicit"
}

require_command docker
require_command jq
require_command curl
log "== WU-46 Stage-1 surfaces test $(date -u +%FT%TZ) (project: $WU46_PROJECT_NAME) =="

compose_json=$("${COMPOSE[@]}" config --format json) || fail "Compose configuration is invalid"
jq -e '[.services[] | .ports[]? | .host_ip] | length > 0 and all(. == "127.0.0.1")' \
  <<<"$compose_json" >/dev/null || fail "published Compose ports are not loopback-only"
loopback_only=true
pass "Compose publishes every service on loopback only"

"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove prior WU-46 Compose state"
log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 || fail "Compose bring-up failed"
wait_for_healthy_services 300 || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

backend_ready=$(curl -fsS "$BACKEND_URL/readyz") || fail "backend /readyz is unavailable"
jq -e '.status == "ok" and .database == true and .migrations == true' <<<"$backend_ready" >/dev/null \
  || fail "backend /readyz is not migration-ready: $backend_ready"

migration_head=$("${PSQL[@]}" -c "SELECT coalesce(max(version), 0) FROM schema_migration;") \
  || fail "could not read migration head"
[[ "$migration_head" == "52" ]] || fail "expected migration head 52, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 52;")
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();")
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();")
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 52 checksum is invalid"
pass "migration 52 and schema identity are recorded"

empty_surface=$(curl -fsS "$BACKEND_URL/stage1-surfaces") \
  || fail "empty stage-1 surface endpoint is unavailable"
jq -e '
  .environment == "local_research"
  and .order_authority == false
  and .stage.stage == 1
  and .stage.display_only == true
  and .qualification.recorded == false
  and .cost.recorded == false
  and .cost_model.recorded == false
  and .snapshots.recorded == false
' <<<"$empty_surface" >/dev/null || fail "empty surface does not expose explicit states: $empty_surface"
curl -fsS "$FRONTEND_URL/surfaces" >"$EMPTY_HTML" || fail "empty frontend surface is unavailable"
grep -q 'id="stage1-surfaces"' "$EMPTY_HTML" || fail "frontend is missing stage-1 root"
grep -q 'data-status="not_recorded"' "$EMPTY_HTML" || fail "frontend hides empty qualification state"
screenshot_url "$FRONTEND_URL/surfaces" "$EMPTY_PNG"
pass "empty stage-1 state is explicit and visible"

run_committed_fixture db/fixtures/wu38_qualification_report_probe.sql \
  wu38-qualification-report-probe.sql wu38_probe_result
run_committed_fixture db/fixtures/wu44_cost_model_probe.sql \
  wu44-cost-model-probe.sql wu44_probe_result
run_committed_fixture db/fixtures/wu16_snapshot_manifest_probe.sql \
  wu16-snapshot-manifest-probe.sql wu16_probe_result

curl -fsS -X POST "$BACKEND_URL/restore-verification" >/dev/null \
  || fail "fixture audit chain did not pass restore verification"
checkpoint=$(curl -fsS -X POST "$BACKEND_URL/checkpoints") || fail "could not create signed checkpoint"
jq -e '.receipt.chain_position > 0' <<<"$checkpoint" >/dev/null || fail "checkpoint response is invalid"

populated_surface=$(curl -fsS "$BACKEND_URL/stage1-surfaces") \
  || fail "populated stage-1 surface endpoint is unavailable"
jq -e '
  .checkpoints_verified == true
  and .qualification.recorded == true
  and .qualification.window_count >= 3
  and (.qualification.eis | type) == "number"
  and (.qualification.lcb_vs_cash_bps | type) == "number"
  and (.qualification.lcb_vs_sp500_bps | type) == "number"
  and .cost.recorded == true
  and .cost_model.recorded == true
  and (.cost_model.within_caps | type) == "boolean"
  and .snapshots.recorded == true
  and .snapshots.manifest_count >= 1
  and .checkpoint_pack.recorded == true
  and .checkpoint_pack.state == "CHECKPOINT VERIFIED"
' <<<"$populated_surface" >/dev/null || fail "populated surface is incomplete: $populated_surface"

curl -fsS "$FRONTEND_URL/surfaces" >"$POPULATED_HTML" || fail "populated frontend surface is unavailable"
for id in stage-badge qualification-progress cost-vs-caps snapshot-browser checkpoint-pack; do
  grep -q "id=\"$id\"" "$POPULATED_HTML" || fail "frontend is missing $id"
done
grep -q 'data-order-authority="none"' "$POPULATED_HTML" || fail "frontend does not declare zero authority"
grep -q 'data-display-only="true"' "$POPULATED_HTML" || fail "frontend does not declare display-only"
if grep -Eq '<(form|button)([ >])' "$POPULATED_HTML"; then
  fail "stage-1 surface renders an authority-bearing control"
fi
method_status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BACKEND_URL/stage1-surfaces")
[[ "$method_status" == "405" ]] || fail "stage-1 backend accepted a write-shaped request ($method_status)"
screenshot_url "$FRONTEND_URL/surfaces" "$POPULATED_PNG"
pass "all five populated surfaces render read-only stage-1 state"

assert_refusal MM_DASHBOARD_PUBLIC_EXPOSE
public_exposure_refused=true
assert_refusal MM_DASHBOARD_ORDER_AUTHORITY
authority_refused=true
pass "dashboard startup refuses remote exposure and authority configuration"

public_execute_revoked=$("${PSQL[@]}" -c \
  "SELECT NOT has_function_privilege('public', 'read_stage1_surfaces()', 'EXECUTE');")
[[ "$public_execute_revoked" == "t" ]] || fail "public execute on read_stage1_surfaces was not revoked"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu46-stage1-surfaces-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-46 probe"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu46-stage1-surfaces-probe.sql \
  -c "SELECT result FROM wu46_probe_result;" -c "ROLLBACK;") \
  || fail "WU-46 projection probe failed"
for key in stage_badge_local_research qualification_progress_projected \
  cost_vs_caps_projected snapshot_browsing_projected checkpoint_pack_projected \
  read_has_no_side_effects no_authority_grant projection_does_not_claim_verification; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "SQL probe projects every stage-1 surface without authority"

record_payload=$(jq -c '{stage: .stage, qualification: .qualification.status, cost_within_caps: .cost_model.within_caps, manifests: .snapshots.manifest_count, checkpoint_state: .checkpoint_pack.state}' <<<"$populated_surface")
chain_record=$(append_audit_event "wu46-record-$(date +%s)" "research.stage1_surfaces_traced" \
  "$(jq -nc --argjson evidence "$record_payload" '{surface: "stage1", evidence: $evidence}')") \
  || fail "audit append stage1_surfaces_traced failed"
chain_gate=$(append_audit_event "wu46-gates-$(date +%s)" "research.stage1_surface_gates_proved" \
  "$(jq -nc --argjson evidence "$probe_result" '{probe: "wu46_stage1_surfaces_probe", evidence: $evidence}')") \
  || fail "audit append stage1_surface_gates_proved failed"
[[ "$chain_gate" -gt "$chain_record" ]] || fail "audit chain positions did not advance"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;")
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson empty "$empty_surface" \
  --argjson populated "$populated_surface" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson migration_head "$migration_head" \
  --arg migration_checksum "$migration_checksum" \
  --arg schema_head "$migration_schema_head" \
  --arg fingerprint "$migration_fingerprint" \
  --arg public_execute_revoked "$public_execute_revoked" \
  --arg loopback_only "$loopback_only" \
  --arg public_exposure_refused "$public_exposure_refused" \
  --arg authority_refused "$authority_refused" \
  --arg base_head "$(git rev-parse HEAD)" \
  --arg source_digest "$(for file in backend/src/checkpoints.rs backend/src/main.rs docker-compose.yml db/fixtures/wu46_stage1_surfaces_probe.sql db/migrations/0052_stage1_surfaces.sql frontend/app/CommandLedger.tsx frontend/app/Stage1Surfaces.tsx frontend/app/command-ledger.css frontend/app/surfaces/page.tsx frontend/app/surfaces/stage1-surfaces-model.ts frontend/package.json frontend/start.mjs scripts/wu46_stage1_surfaces_test.sh; do printf '%s ' "$file"; git hash-object "$file"; done | shasum -a 256 | cut -d' ' -f1)" \
  --argjson audit_record "$chain_record" \
  --argjson audit_gates "$chain_gate" \
  '{
    captured_at: $captured_at,
    migration: {head: $migration_head, expected_head: 52, version: 52, name: "stage1_surfaces", checksum: $migration_checksum, schema_head: $schema_head, fingerprint: $fingerprint},
    empty_state: $empty,
    populated_state: $populated,
    probe: $probe,
    source: {base_head: $base_head, digest: $source_digest},
    configuration: {loopback_only: ($loopback_only == "true"), public_exposure_refused: ($public_exposure_refused == "true"), authority_refused: ($authority_refused == "true"), public_execute_revoked: ($public_execute_revoked == "t")},
    screenshots: {empty: "evidence/wu-46/stage1-surfaces-empty.png", populated: "evidence/wu-46/stage1-surfaces-populated.png"},
    audit_chain: $chain,
    audit_positions: {record: $audit_record, gates: $audit_gates}
  }' >"$REPORT" || fail "could not write WU-46 evidence report"

jq -e '
  .migration.head == 52
  and .probe.stage_badge_local_research == true
  and .probe.qualification_progress_projected == true
  and .probe.cost_vs_caps_projected == true
  and .probe.snapshot_browsing_projected == true
  and .probe.checkpoint_pack_projected == true
  and .configuration.loopback_only == true
  and .configuration.public_exposure_refused == true
  and .configuration.authority_refused == true
  and .configuration.public_execute_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
' "$REPORT" >/dev/null || fail "WU-46 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" && -s "$EMPTY_HTML" && -s "$POPULATED_HTML" \
  && -s "$EMPTY_PNG" && -s "$POPULATED_PNG" && -s "$REFUSAL_LOG" ]] \
  || fail "named WU-46 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-46 COMPLETE"
