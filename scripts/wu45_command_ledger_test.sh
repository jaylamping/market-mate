#!/usr/bin/env bash
# WU-45 executable acceptance test — dashboard command ledger (variant A).
# Evidence: dashboard screenshot set on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-45"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/dashboard-screenshot-set.json"
TRUSTED_HTML="$EVIDENCE_DIR/command-ledger-trusted.html"
TAMPERED_HTML="$EVIDENCE_DIR/command-ledger-tampered.html"
TRUSTED_PNG="$EVIDENCE_DIR/command-ledger-trusted.png"
TAMPERED_PNG="$EVIDENCE_DIR/command-ledger-tampered.png"
PROBE_SQL="db/fixtures/wu45_command_ledger_probe.sql"
WU45_PROJECT_NAME="${WU45_COMPOSE_PROJECT_NAME:-market-mate-wu45}"
COMPOSE=(docker compose --project-name "$WU45_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)
BACKEND_URL="${WU45_BACKEND_URL:-http://127.0.0.1:8080}"
FRONTEND_URL="${WU45_FRONTEND_URL:-http://127.0.0.1:3000}"

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT" "$TRUSTED_HTML" "$TAMPERED_HTML" "$TRUSTED_PNG" "$TAMPERED_PNG"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-45 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-45 PASS: $1"; }
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
      '{\"source\":\"wu45-acceptance\",\"entitlement_version\":\"command-ledger-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

write_ledger_html() {
  local dest="$1"
  python3 - "$2" "$dest" <<'PY'
import json, html, sys
ledger = json.loads(sys.argv[1]) if sys.argv[1].startswith("{") else json.load(open(sys.argv[1]))
dest = sys.argv[2]
truth = ledger["system_truth"]
distrusted = (not ledger["chain"]["valid"]) or (not ledger["checkpoints_verified"])
break_pos = ledger["chain"].get("break_position")
rows = []
for event in ledger["tape"]:
    trusted = bool(event.get("trusted"))
    cls = "" if trusted else ' class="is-distrusted"'
    reason = event.get("distrust_reason") or "untrusted"
    rows.append(
        f'<tr{cls} data-chain-position="{event["chain_position"]}" data-trusted="{str(trusted).lower()}">'
        f'<td>{event["chain_position"]}</td><td><strong>{html.escape(event["event_type"])}</strong></td>'
        f'<td>{html.escape(event["event_time"])}</td><td>{"trusted" if trusted else html.escape(str(reason))}</td></tr>'
    )
exceptions = ledger.get("exceptions") or []
if exceptions:
    rail = "".join(
        f'<article data-exception-kind="{html.escape(item["kind"])}" data-exception-position="{item.get("position") or ""}">'
        f'<strong>{html.escape(item["kind"])}'
        f'{" @ " + str(item["position"]) if item.get("position") is not None else ""}</strong>'
        f'<small>{html.escape(item.get("reason") or "")}: {html.escape(item.get("detail") or "")}</small></article>'
        for item in exceptions
    )
else:
    rail = '<p class="empty">No exceptions. Chain and checkpoints verify.</p>'
page = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Market Mate — Command Ledger</title>
<link rel="stylesheet" href="./command-ledger.css"></head>
<body>
<div id="command-ledger" class="variant-a" data-variant="{html.escape(ledger.get("variant",""))}" data-chain-valid="{str(ledger["chain"]["valid"]).lower()}" data-checkpoints-verified="{str(ledger["checkpoints_verified"]).lower()}" data-order-authority="{str(ledger.get("order_authority", False)).lower()}" data-break-position="{"" if break_pos is None else break_pos}">
<aside class="command-sidebar"><div class="brand-sidebar"><strong>MARKET MATE</strong><small>COMMAND LEDGER</small></div></aside>
<main class="command-main">
<section id="system-truth-header" class="truth-bar{" is-distrusted" if distrusted else ""}" data-state="{html.escape(truth["state"])}">
<div><span class="env-label">{html.escape(truth["environment"])}</span></div>
<p>{html.escape(truth["detail"])}</p>
</section>
<div class="command-grid">
<section class="command-section"><table id="audit-tape" class="audit-tape"><tbody>{"".join(rows)}</tbody></table></section>
<aside id="exception-rail" class="command-section exception-rail" data-count="{len(exceptions)}" data-break-position="{"" if break_pos is None else break_pos}">{rail}</aside>
</div></main></div>
</body></html>'''
open(dest, "w", encoding="utf-8").write(page)
PY
}

screenshot_url() {
  local url="$1" dest="$2"
  local chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  if [[ -x "$chrome" ]]; then
    "$chrome" --headless --disable-gpu --hide-scrollbars --window-size=1440,900 \
      --screenshot="$dest" "$url" >>"$BRING_UP_LOG" 2>&1 || true
  fi
}

require_command docker
require_command jq
require_command python3
log "== WU-45 Command ledger test $(date -u +%FT%TZ) (project: $WU45_PROJECT_NAME) =="
"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30 market-mate-wu31 market-mate-wu32 market-mate-wu33 market-mate-wu34 market-mate-wu35 market-mate-wu36 market-mate-wu37 market-mate-wu38 market-mate-wu39 market-mate-wu40 market-mate-wu41 market-mate-wu42 market-mate-wu43 market-mate-wu44 market-mate-wu45 market-mate-wu46 market-mate-wu47 market-mate-wu48 market-mate-wu49 market-mate-wu50 market-mate-harden-wu28-31; do
  [[ "$sibling" == "$WU45_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-45 Compose state"
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
[[ "$migration_head" == "51" ]] || fail "expected migration head 51, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 51;") \
  || fail "could not read migration 51 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 51 checksum is invalid: $migration_checksum"
pass "migration 51 and schema identity are recorded"

unverified=$(curl -fsS "$BACKEND_URL/command-ledger") \
  || fail "command ledger is unavailable before checkpoint"
jq -e '.checkpoints_verified == false and .system_truth.state == "CHECKPOINT UNVERIFIED"' <<<"$unverified" >/dev/null \
  || fail "ledger displayed as trusted without a checkpoint: $unverified"
pass "checkpoints are verified before trusted display"

checkpoint=$(curl -fsS -X POST "$BACKEND_URL/checkpoints") \
  || fail "could not create a signed checkpoint"
jq -e '.receipt.chain_position > 0' <<<"$checkpoint" >/dev/null \
  || fail "checkpoint response is invalid: $checkpoint"

trusted_ledger=$(curl -fsS "$BACKEND_URL/command-ledger") \
  || fail "command ledger is unavailable after checkpoint"
jq -e '
  .variant == "A"
  and .environment == "local_research"
  and .order_authority == false
  and .checkpoints_verified == true
  and .chain.valid == true
  and .system_truth.state == "CHAIN VERIFIED"
  and (.tape | length) >= 1
  and all(.tape[]; .trusted == true)
' <<<"$trusted_ledger" >/dev/null \
  || fail "verified command ledger is not trusted variant A: $trusted_ledger"
pass "signed chain projects variant A after checkpoint verification"

curl -fsS "$FRONTEND_URL/" >"$TRUSTED_HTML" || fail "frontend command ledger is unavailable"
grep -q 'id="command-ledger"' "$TRUSTED_HTML" || fail "dashboard does not render the command ledger"
grep -q 'id="system-truth-header"' "$TRUSTED_HTML" || fail "dashboard is missing the system-truth header"
grep -q 'id="audit-tape"' "$TRUSTED_HTML" || fail "dashboard is missing the dense audit tape"
grep -q 'id="exception-rail"' "$TRUSTED_HTML" || fail "dashboard is missing the exception rail"
grep -q 'data-variant="A"' "$TRUSTED_HTML" || fail "dashboard is not variant A"
grep -q 'data-chain-valid="true"' "$TRUSTED_HTML" || fail "trusted dashboard does not mark the chain valid"
grep -q 'data-checkpoints-verified="true"' "$TRUSTED_HTML" || fail "trusted dashboard does not mark checkpoints verified"
grep -q 'CHAIN VERIFIED' "$TRUSTED_HTML" || fail "system-truth header does not show verified state"
pass "NextJS renders variant A from the signed audit chain"

public_execute_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_function_privilege('public', 'read_command_ledger()', 'EXECUTE');
") || fail "could not inspect public command-ledger execute privilege"
[[ "$public_execute_revoked" == "t" ]] || fail "public execute on read_command_ledger was not revoked"

"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu45-command-ledger-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-45 probe into the postgres container"
probe_result=$("${PSQL[@]}" -c "BEGIN;" -f /tmp/wu45-command-ledger-probe.sql \
  -c "SELECT result FROM wu45_probe_result;" -c "ROLLBACK;") \
  || fail "WU-45 command ledger probe failed: $probe_result"

for key in variant_a local_research no_order_authority \
  checkpoints_verified_before_display tamper_distrusts_affected_range; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
pass "tampered chain distrusts the affected range"

jq -c '.tampered_ledger' <<<"$probe_result" >"$EVIDENCE_DIR/command-ledger-tampered.json"
cp frontend/app/command-ledger.css "$EVIDENCE_DIR/command-ledger.css"
write_ledger_html "$TAMPERED_HTML" "$EVIDENCE_DIR/command-ledger-tampered.json"
grep -q 'data-chain-valid="false"' "$TAMPERED_HTML" || fail "tampered dashboard HTML does not mark the chain invalid"
grep -q 'id="exception-rail"' "$TAMPERED_HTML" || fail "tampered dashboard HTML is missing the exception rail"
grep -q 'data-trusted="false"' "$TAMPERED_HTML" || fail "tampered dashboard HTML does not mark the affected range untrusted"
grep -q 'CHAIN DISTRUSTED' "$TAMPERED_HTML" || fail "tampered dashboard HTML does not show distrusted system truth"
pass "dashboard visibly distrusts the affected range"

screenshot_url "$FRONTEND_URL/" "$TRUSTED_PNG"
if [[ -s "$TAMPERED_HTML" ]]; then
  screenshot_url "file://$PWD/$TAMPERED_HTML" "$TAMPERED_PNG"
fi

record_payload=$(jq -c '{variant_a, local_research, no_order_authority, checkpoints_verified_before_display}' <<<"$probe_result")
gate_payload=$(jq -c '{tamper_distrusts_affected_range, break_position, tamper_position}' <<<"$probe_result")
chain_record=$(append_audit_event "wu45-record-$(date +%s)" "research.command_ledger_traced" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu45_command_ledger_probe", evidence: $evidence}')") \
  || fail "audit append command_ledger_traced failed"
chain_gate=$(append_audit_event "wu45-gates-$(date +%s)" "research.command_ledger_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu45_command_ledger_probe", evidence: $evidence}')") \
  || fail "audit append command_ledger_gates_proved failed"
[[ "$chain_gate" -gt "$chain_record" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_gate"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "command ledger evidence is recorded on the verified audit chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson probe "$probe_result" \
  --argjson chain "$chain_ok" \
  --argjson migration_head "$migration_head" \
  --arg migration_checksum "$migration_checksum" \
  --arg migration_schema_head "$migration_schema_head" \
  --arg migration_fingerprint "$migration_fingerprint" \
  --arg public_execute_revoked "$public_execute_revoked" \
  --argjson audit_position_record "$chain_record" \
  --argjson audit_position_gates "$chain_gate" \
  --arg trusted_html "$TRUSTED_HTML" \
  --arg tampered_html "$TAMPERED_HTML" \
  --arg trusted_png "$TRUSTED_PNG" \
  --arg tampered_png "$TAMPERED_PNG" \
  '{
    captured_at: $captured_at,
    migration: {
      head: $migration_head,
      expected_head: 51,
      version: 51,
      name: "command_ledger",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    dashboard: {
      variant: "A",
      trusted_html: $trusted_html,
      tampered_html: $tampered_html,
      trusted_png: $trusted_png,
      tampered_png: $tampered_png
    },
    ledger: {
      variant_a: $probe.variant_a,
      local_research: $probe.local_research,
      no_order_authority: $probe.no_order_authority,
      checkpoints_verified_before_display: $probe.checkpoints_verified_before_display,
      tamper_distrusts_affected_range: $probe.tamper_distrusts_affected_range
    },
    append_only_and_fail_closed: {
      public_execute_revoked: ($public_execute_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates
    }
  }' >"$REPORT" || fail "could not write WU-45 evidence report"
jq -e '
  .migration.head == 51
  and .migration.expected_head == 51
  and .ledger.variant_a == true
  and .ledger.checkpoints_verified_before_display == true
  and .ledger.tamper_distrusts_affected_range == true
  and .append_only_and_fail_closed.public_execute_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
' "$REPORT" >/dev/null || fail "WU-45 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" && -s "$TRUSTED_HTML" && -s "$TAMPERED_HTML" ]] \
  || fail "named WU-45 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-45 COMPLETE"
