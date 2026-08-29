#!/usr/bin/env bash
# WU-05 executable acceptance test — credential-free config and secret boundary.
# Evidence: startup scan report written to evidence/wu-05/.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-05"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/startup-scan-report.json"
WU05_PROJECT_NAME="${WU05_COMPOSE_PROJECT_NAME:-market-mate-wu05}"
COMPOSE=(docker compose --project-name "$WU05_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() {
  printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"
}

fail() {
  log "WU-05 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}

pass() {
  log "WU-05 PASS: $1"
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

append_event() {
  local event_id="$1"
  local event_type="$2"
  local payload="$3"

  "${PSQL[@]}" -qAtc "
    SELECT chain_position FROM append_audit_event(
      '$event_id',
      '$event_type',
      now(),
      '$payload'::jsonb,
      '{\"source\":\"wu05-acceptance\",\"entitlement_version\":\"local-v1\"}'::jsonb,
      now(),
      'local_research'
    );
  "
}

require_command curl
require_command docker
require_command jq

log "== WU-05 credential scan test $(date -u +%FT%TZ) (project: $WU05_PROJECT_NAME) =="

"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose configuration is invalid"

for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06; do
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove prior WU-05 Compose state"

log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose bring-up failed"

wait_for_healthy_services 180 \
  || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

# 1. Startup scan of the backend service environment must pass with zero violations.
env_scan_output=$("${COMPOSE[@]}" exec -T backend backend scan-config) \
  || fail "backend environment scan exited nonzero: $env_scan_output"
jq -e '.result == "pass" and (.violations | length) == 0 and .profile == "local_research"' \
  <<<"$env_scan_output" >/dev/null \
  || fail "backend environment scan did not pass: $env_scan_output"
env_scan_report=$(jq -c . <<<"$env_scan_output")
pass "backend service environment scan: zero violations"

# 2. Scan the merged Compose environment of every service through the same detectors.
compose_json=$("${COMPOSE[@]}" config --format json) \
  || fail "could not render Compose configuration"
env_map=$(jq -c '
  def to_env:
    if type == "object" then .
    elif type == "array" then
      map(capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}) | add // {}
    else {} end;
  [.services[].environment // {} | to_env] | add // {}
' <<<"$compose_json") \
  || fail "could not merge Compose service environments"
compose_scan_tmp=$(mktemp -d /tmp/wu05.XXXXXX)
trap 'rm -rf "$compose_scan_tmp"' EXIT
printf '%s' "$env_map" >"$compose_scan_tmp/env.json"
"${COMPOSE[@]}" cp "$compose_scan_tmp/env.json" backend:/tmp/wu05-env.json \
  >>"$BRING_UP_LOG" 2>&1 || fail "could not copy the environment map into the backend container"
compose_scan_output=$("${COMPOSE[@]}" exec -T backend backend scan-config --json-file /tmp/wu05-env.json) \
  || fail "Compose environment scan exited nonzero: $compose_scan_output"
jq -e '.result == "pass" and (.violations | length) == 0' \
  <<<"$compose_scan_output" >/dev/null \
  || fail "Compose environment scan did not pass: $compose_scan_output"
compose_scan_report=$(jq -c . <<<"$compose_scan_output")
pass "merged Compose environment scan: zero violations"

# 3. Every backend and custody log line is structured JSON.
for service in backend custody; do
  "${COMPOSE[@]}" logs --no-log-prefix "$service" 2>/dev/null \
    | jq -e . >/dev/null \
    || fail "$service produced a non-structured (non-JSON) log line"
done
backend_log_count=$("${COMPOSE[@]}" logs --no-log-prefix backend | jq -s 'length')
custody_log_count=$("${COMPOSE[@]}" logs --no-log-prefix custody | jq -s 'length')
[[ "$backend_log_count" -gt 0 && "$custody_log_count" -gt 0 ]] \
  || fail "expected structured log lines from backend and custody, found $backend_log_count/$custody_log_count"
pass "all backend and custody log lines are structured JSON"

# 4. Redaction demo: a secret-shaped log value never reaches the log line.
demo_output=$("${COMPOSE[@]}" exec -T backend backend scan-config --redact-demo \
  "DATABASE_URL=postgres://mm:local-only@postgres:5432/market_mate") \
  || fail "redaction demo failed: $demo_output"
if grep -q 'local-only' <<<"$demo_output"; then
  fail "redaction demo leaked the URL password: $demo_output"
fi
grep -q '\[REDACTED:url-password\]' <<<"$demo_output" \
  || fail "redaction demo did not redact the URL password: $demo_output"
jq -e . <<<"$demo_output" >/dev/null \
  || fail "redaction demo did not produce a structured JSON log line"
redaction_demo=$(jq -nc \
  --arg input "postgres://mm:local-only@postgres:5432/market_mate" \
  --arg output "$demo_output" \
  '{input: $input, output: ($output | fromjson)}')
pass "redaction demo: URL password replaced with [REDACTED:url-password]"

# 5. Fail-closed probes: credential-shaped config must block with a report that
#    names the violation but never carries the secret value.
probe_hex="9f2c5a1e7b3d4f6a8c0e2b4d6f8a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a"
probe_pem="-----BEGIN RSA PRIVATE KEY-----
MIICXAIBAAKBgQC0demoMaterialNeverARealKey
-----END RSA PRIVATE KEY-----"
probe_jwt="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ3dTA1In0.c2lnbmF0dXJlLW1hdGVyaWFs"

declare -a PROBE_NAMES=() PROBE_STATUSES=() PROBE_REPORTS=()

run_probe() {
  local name="$1"
  local expected_detector="$2"
  shift 2
  local output
  local status=0
  output=$("${COMPOSE[@]}" run --rm --no-deps "$@" 2>/dev/null) || status=$?
  [[ "$status" == "1" ]] \
    || fail "probe $name did not exit 1 (status=$status): $output"
  jq -e '.result == "blocked" and (.violations | length) >= 1' \
    <<<"$output" >/dev/null \
    || fail "probe $name did not produce a blocked report: $output"
  jq -e --arg d "$expected_detector" '.violations[0].detector == $d' \
    <<<"$output" >/dev/null \
    || fail "probe $name hit the wrong detector: $output"
  if grep -q "$probe_hex" <<<"$output"; then
    fail "probe $name report leaked the probe secret value"
  fi
  PROBE_NAMES+=("$name")
  PROBE_STATUSES+=("$status")
  PROBE_REPORTS+=("$(jq -c . <<<"$output")")
  pass "probe $name blocked by $expected_detector without leaking the value"
}

run_probe "broker-api-key-name" "api-key-named-variable" \
  -e "ALPACA_API_KEY=$probe_hex" \
  backend backend scan-config

run_probe "pem-private-key-value" "pem-private-key" \
  -e "CERT_BLOB=$probe_pem" \
  backend backend scan-config

run_probe "jwt-value" "jwt-credential" \
  -e "SESSION_STATE=$probe_jwt" \
  backend backend scan-config

# 6. The serve path fails closed before any service work starts.
serve_status=0
serve_log=$("${COMPOSE[@]}" run --rm --no-deps -e "ALPACA_API_KEY=$probe_hex" backend 2>&1) || serve_status=$?
[[ "$serve_status" == "1" ]] \
  || fail "serve exited with status $serve_status, expected 1"
grep -q '"event":"config.startup_blocked"' <<<"$serve_log" \
  || fail "serve gate did not log config.startup_blocked: $serve_log"
if grep -q "$probe_hex" <<<"$serve_log"; then
  fail "serve gate log leaked the probe secret value"
fi
blocked_log_line=$(printf '%s' "$serve_log" | tail -1)
jq -e '.event == "config.startup_blocked" and .level == "error"' \
  <<<"$blocked_log_line" >/dev/null \
  || fail "blocked startup log line is not the expected structured event: $blocked_log_line"
serve_gate=$(jq -nc --argjson blocked_log_line "$blocked_log_line" \
  '{startup_blocked_logged: true, blocked_log_line: $blocked_log_line}')
pass "serve path refused to start on credential-shaped config"

# 7. Material actions land on the append-only audit chain.
audit_positions=()
position=$(append_event "wu05-scan-$(date +%s)" "config.startup_scan_completed" \
  "{\"surface\":\"compose_environment\",\"variables_scanned\":$(jq '.variables_scanned' <<<"$compose_scan_output"),\"violations\":0,\"result\":\"pass\"}") \
  || fail "config.startup_scan_completed audit append failed"
audit_positions+=("$(jq -nc --arg t config.startup_scan_completed --argjson p "$position" '{event_type: $t, chain_position: $p}')")
pass "startup scan completion recorded on the audit chain at position $position"

for index in "${!PROBE_NAMES[@]}"; do
  name="${PROBE_NAMES[$index]}"
  detector="${PROBE_REPORTS[$index]}"
  position=$(append_event "wu05-block-$(date +%s)-$index" "config.scan_blocked" \
    "{\"probe\":\"$name\",\"report\":$(jq -c '.violations' <<<"${PROBE_REPORTS[$index]}")}") \
    || fail "config.scan_blocked audit append failed for $name"
  audit_positions+=("$(jq -nc --arg t config.scan_blocked --argjson p "$position" '{event_type: $t, chain_position: $p}')")
done
pass "blocked probes recorded on the audit chain"

# 8. Assemble and validate the evidence report.
probes_json=$(jq -nc \
  --argjson names "$(printf '%s\n' "${PROBE_NAMES[@]}" | jq -R . | jq -s .)" \
  --argjson statuses "$(printf '%s\n' "${PROBE_STATUSES[@]}" | jq -s .)" \
  --argjson reports "$(printf '%s\n' "${PROBE_REPORTS[@]}" | jq -s .)" \
  'reduce range(0, ($names | length)) as $i ([]; . + [{name: $names[$i], exit_code: $statuses[$i], report: $reports[$i]}])')

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson environment_scan "$env_scan_report" \
  --argjson compose_scan "$compose_scan_report" \
  --argjson backend_log_count "$backend_log_count" \
  --argjson custody_log_count "$custody_log_count" \
  --argjson redaction_demo "$redaction_demo" \
  --argjson probes "$probes_json" \
  --argjson serve_gate "$serve_gate" \
  --argjson audit_events "$(printf '%s\n' "${audit_positions[@]}" | jq -s .)" \
  '{
    captured_at: $captured_at,
    environment_scan: $environment_scan,
    compose_config_scan: $compose_scan,
    structured_logs: {
      backend_lines: $backend_log_count,
      custody_lines: $custody_log_count,
      all_lines_valid_json: true
    },
    redaction_demo: $redaction_demo,
    negative_probes: $probes,
    serve_gate: $serve_gate,
    audit_events: $audit_events
  }' >"$REPORT" \
  || fail "could not write startup scan report"

jq -e '
  .environment_scan.result == "pass"
  and (.environment_scan.violations | length) == 0
  and .compose_config_scan.result == "pass"
  and .structured_logs.backend_lines > 0
  and .structured_logs.custody_lines > 0
  and .redaction_demo.output.DATABASE_URL == "postgres://mm:[REDACTED:url-password]@postgres:5432/market_mate"
  and (.negative_probes | length) == 3
  and all(.negative_probes[]; .exit_code == 1 and (.report.violations | length) >= 1)
  and .serve_gate.startup_blocked_logged == true
  and (.audit_events | length) == 4
  and .audit_events[0].event_type == "config.startup_scan_completed"
' "$REPORT" >/dev/null \
  || fail "startup scan report does not satisfy the WU-05 evidence schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] \
  || fail "named WU-05 evidence is not retrievable"

pass "valid evidence is retrievable at $REPORT"
log "WU-05 COMPLETE"
