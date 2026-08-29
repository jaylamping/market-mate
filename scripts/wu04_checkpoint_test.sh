#!/usr/bin/env bash
# WU-04 executable acceptance test — signed checkpoint receipts and the
# restore-verification gate. Evidence: checkpoint receipt report written to
# evidence/wu-04/.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-04"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/checkpoint-receipt-report.json"
WU04_PROJECT_NAME="${WU04_COMPOSE_PROJECT_NAME:-market-mate-wu04}"
COMPOSE=(docker compose --project-name "$WU04_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -U mm -d market_mate)
CUSTODY_URL="${WU04_CUSTODY_URL:-http://127.0.0.1:8081}"
BACKEND_URL="${WU04_BACKEND_URL:-http://127.0.0.1:8080}"

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() {
  printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"
}

fail() {
  log "WU-04 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}

pass() {
  log "WU-04 PASS: $1"
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

wait_for_service_healthy() {
  local service="$1"
  local attempts="$2"
  local attempt
  local health

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    health=$("${COMPOSE[@]}" ps --format json 2>/dev/null \
      | jq -r --arg s "$service" 'select(.Service == $s) | .Health' 2>/dev/null || true)
    if [[ "$health" == "healthy" ]]; then
      return 0
    fi
    sleep 2
  done

  return 1
}

wait_for_readyz_status() {
  local expected_status="$1"
  local attempts="$2"
  local attempt
  local status

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    status=$(curl -s -o /dev/null -w '%{http_code}' "$BACKEND_URL/readyz" 2>/dev/null || true)
    if [[ "$status" == "$expected_status" ]]; then
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
    SELECT row_to_json(event_row)
    FROM append_audit_event(
      '$event_id',
      '$event_type',
      now(),
      '$payload'::jsonb,
      '{\"source\":\"wu04-acceptance\",\"entitlement_version\":\"local-v1\"}'::jsonb,
      now(),
      'local_research'
    ) AS event_row;
  "
}

require_command curl
require_command docker
require_command jq
require_command shasum
require_command xxd
require_command openssl

log "== WU-04 checkpoint test $(date -u +%FT%TZ) (project: $WU04_PROJECT_NAME) =="

"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose configuration is invalid"

for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09; do
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove prior WU-04 Compose state"

log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose bring-up failed"

wait_for_healthy_services 180 \
  || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack including custody is healthy"

# 1. Startup restore verification gates readiness from a clean boot.
readyz_initial=$(curl -fsS "$BACKEND_URL/readyz") \
  || fail "backend /readyz is unavailable"
jq -e '
  .status == "ok"
  and .database == true
  and .migrations == true
  and .checkpoints == true
  and .checkpoint_pending == false
' <<<"$readyz_initial" >/dev/null \
  || fail "readiness did not include a passed restore verification: $readyz_initial"
pass "restore verification passed at startup (empty chain, no receipts)"

custody_public_key=$(curl -fsS "$CUSTODY_URL/public-key") \
  || fail "custody public key is unavailable"
jq -e '.algorithm == "ed25519" and (.public_key | length) == 64' \
  <<<"$custody_public_key" >/dev/null \
  || fail "custody did not publish an ed25519 public key: $custody_public_key"
custody_key_hex=$(jq -r '.public_key' <<<"$custody_public_key")
pass "custody holds its own ed25519 key"

receipts_initial=$(curl -fsS "$CUSTODY_URL/receipts") \
  || fail "custody receipts are unavailable"
jq -e '. == []' <<<"$receipts_initial" >/dev/null \
  || fail "custody receipt store is not empty at boot: $receipts_initial"

# 2. Append canonical events, then fire a checkpoint and validate the receipt.
for index in 1 2 3; do
  append_event "wu04-000$index" "wu04.chain_event" "{\"index\":$index}" >/dev/null \
    || fail "canonical event $index append failed"
done
pass "three canonical events appended"

checkpointed_head=$("${PSQL[@]}" -qAtc \
  "SELECT coalesce(max(chain_position), 0) FROM audit_event;") \
  || fail "could not read chain head position"
[[ "$checkpointed_head" -ge 3 ]] \
  || fail "expected at least 3 chain events before the checkpoint, found $checkpointed_head"

checkpoint_response=$(curl -fsS -X POST "$BACKEND_URL/checkpoints") \
  || fail "checkpoint firing failed"
receipt=$(jq -r '.receipt' <<<"$checkpoint_response")
audit_position_one=$(jq -r '.audit_chain_position' <<<"$checkpoint_response")
jq -e '
  .checkpoint_index == 1
  and .chain_position == '"$checkpointed_head"'
  and (.checkpoint_time | length) == 27
  and (.checkpoint_time | endswith("Z"))
  and .algorithm == "ed25519"
  and .public_key == "'"$custody_key_hex"'"
  and (.signature | length) == 128
' <<<"$receipt" >/dev/null \
  || fail "checkpoint receipt is not well-formed: $receipt"

chain_digest_domain="market-mate-checkpoint-digest-v1"
head_hash=$("${PSQL[@]}" -qAtc \
  "SELECT event_hash FROM audit_event WHERE chain_position = $checkpointed_head;") \
  || fail "could not read chain head hash"
expected_digest=$(printf '%s|%s|%s' "$chain_digest_domain" "$checkpointed_head" "$head_hash" \
  | shasum -a 256 | cut -d' ' -f1)
[[ "$(jq -r '.chain_digest' <<<"$receipt")" == "$expected_digest" ]] \
  || fail "receipt digest is not the independently recomputed chain digest"
pass "receipt binds chain position $checkpointed_head to the recomputed digest"

# 3. Independently verify the ed25519 signature outside the service boundary.
scratch_dir=$(mktemp -d /tmp/wu04.XXXXXX)
trap 'rm -rf "$scratch_dir"' EXIT
printf '302a300506032b6570032100%s' "$custody_key_hex" | xxd -r -p >"$scratch_dir/pub.der"
openssl pkey -pubin -inform DER -in "$scratch_dir/pub.der" -out "$scratch_dir/pub.pem" \
  >>"$BRING_UP_LOG" 2>&1 || fail "could not convert custody public key to PEM"
canonical=$(jq -r '"market-mate-checkpoint-receipt-v1|\(.checkpoint_index)|\(.chain_position)|\(.chain_digest)|\(.checkpoint_time)"' \
  <<<"$receipt")
printf '%s' "$canonical" >"$scratch_dir/message.bin"
jq -r '.signature' <<<"$receipt" | xxd -r -p >"$scratch_dir/signature.bin"
openssl_output=$(openssl pkeyutl -verify \
  -pubin -inkey "$scratch_dir/pub.pem" \
  -rawin -in "$scratch_dir/message.bin" \
  -sigfile "$scratch_dir/signature.bin" 2>&1) \
  || fail "independent ed25519 verification failed: $openssl_output"
grep -q 'Signature Verified Successfully' <<<"$openssl_output" \
  || fail "openssl verification output was not affirmative: $openssl_output"
pass "receipt signature verified independently with openssl"

mirror_row=$("${PSQL[@]}" -qAtc "
  SELECT row_to_json(m)
  FROM (SELECT checkpoint_index, chain_position, chain_digest, signature
        FROM audit_checkpoint WHERE checkpoint_index = 1) m;
") || fail "audit_checkpoint mirror query failed"
[[ "$(jq -r '.signature' <<<"$mirror_row")" == "$(jq -r '.signature' <<<"$receipt")" ]] \
  || fail "database mirror row does not carry the custody signature"
custody_receipts_one=$(curl -fsS "$CUSTODY_URL/receipts")
[[ "$(jq 'length' <<<"$custody_receipts_one")" == "1" ]] \
  || fail "custody did not retain the receipt"
[[ "$(jq -r '.[0].signature' <<<"$custody_receipts_one")" == "$(jq -r '.signature' <<<"$receipt")" ]] \
  || fail "custody receipt store diverges from the issued receipt"
pass "receipt is mirrored in the database and retained in custody"

chain_checkpoint_event=$("${PSQL[@]}" -qAtc \
  "SELECT event_type FROM audit_event WHERE chain_position = $audit_position_one;") \
  || fail "checkpoint audit event is missing"
[[ "$chain_checkpoint_event" == "audit.checkpoint_created" ]] \
  || fail "expected audit.checkpoint_created event, found $chain_checkpoint_event"
pass "checkpoint material action is on the audit chain at position $audit_position_one"

# 4. Tamper probes: receipts must catch both raw and consistent rewrites.
tamper_target=$("${PSQL[@]}" -qAtc \
  "SELECT min(chain_position) FROM audit_event WHERE event_type = 'wu04.chain_event';") \
  || fail "could not pick a tamper target"

payload_only_probe=$("${PSQL[@]}" -qAtc "
  BEGIN;
  SET LOCAL session_replication_role = replica;
  UPDATE audit_event
     SET payload = '{\"tampered\":true}'::jsonb
   WHERE chain_position = $tamper_target;
  SELECT row_to_json(result) FROM verify_audit_event_chain() AS result;
  ROLLBACK;
") || fail "payload-only tamper probe failed to run"
jq -e '.valid == false and .reason == "event_hash_mismatch"' \
  <<<"$payload_only_probe" >/dev/null \
  || fail "payload tampering was not caught by the chain: $payload_only_probe"

consistent_rewrite_sql="
  BEGIN;
  SET LOCAL session_replication_role = replica;
  UPDATE audit_event
     SET payload = '{\"tampered\":true}'::jsonb
   WHERE chain_position = $tamper_target;
  DO \$\$
  DECLARE
    rewritten record;
    carried_hash text;
    calculated_hash text;
  BEGIN
    SELECT previous_hash INTO carried_hash
      FROM audit_event WHERE chain_position = $tamper_target;
    FOR rewritten IN
      SELECT * FROM audit_event WHERE chain_position >= $tamper_target ORDER BY chain_position
    LOOP
      calculated_hash := canonical_audit_event_hash(
        rewritten.chain_position, carried_hash, rewritten.event_id,
        rewritten.event_type, rewritten.event_time, rewritten.payload,
        rewritten.source_lineage, rewritten.receipt_time, rewritten.record_environment);
      UPDATE audit_event
         SET previous_hash = carried_hash, event_hash = calculated_hash
       WHERE chain_position = rewritten.chain_position;
      carried_hash := calculated_hash;
    END LOOP;
  END
  \$\$;
"

rewrite_tamper_output=$("${PSQL[@]}" -qAtc "
  $consistent_rewrite_sql
  SELECT row_to_json(result) FROM verify_audit_event_chain() AS result;
  ROLLBACK;
") || fail "consistent-rewrite tamper probe failed to run"
jq -e '.valid == true' <<<"$rewrite_tamper_output" >/dev/null \
  || fail "consistent rewrite did not produce an internally valid chain"

rewrite_verification=$("${PSQL[@]}" -qAtc "
  $consistent_rewrite_sql
  SELECT current_chain_digest();
  ROLLBACK;
") || fail "consistent-rewrite digest probe failed to run"
[[ "$rewrite_verification" != "$expected_digest" ]] \
  || fail "consistent rewrite did not change the checkpoint digest"
[[ ${#rewrite_verification} == 64 ]] \
  || fail "consistent rewrite digest is not a sha256 hex string: $rewrite_verification"
pass "tamper probes confirm both chain and receipt detection layers"

# Capture the restore source NOW: the committed tamper below must not enter it.
"${COMPOSE[@]}" exec -T postgres pg_dump -U mm --no-owner --no-privileges market_mate \
  >"$scratch_dir/pre-tamper.sql" \
  || fail "pre-tamper dump failed"
[[ -s "$scratch_dir/pre-tamper.sql" ]] || fail "pre-tamper dump is empty"
dump_bytes=$(wc -c <"$scratch_dir/pre-tamper.sql" | tr -d ' ')
log "-- pre-tamper dump captured ($dump_bytes bytes)"

# 5. Restart gates: committed tampers (both broken chain and consistent rewrite) must refuse to resume.
"${PSQL[@]}" -qAtc "BEGIN; SET LOCAL session_replication_role = replica; UPDATE audit_event SET payload = '{\"tampered\":true}'::jsonb WHERE chain_position = $tamper_target; COMMIT;" >/dev/null \
  || fail "committed payload tamper failed"
log "-- docker compose restart backend (tampered payload)"
"${COMPOSE[@]}" restart backend >>"$BRING_UP_LOG" 2>&1 \
  || fail "backend restart failed"
wait_for_readyz_status 503 60 \
  || fail "backend did not fail readiness with a tampered chain"
tampered_readyz_body=$(curl -sS "$BACKEND_URL/readyz") \
  || fail "could not read tampered readyz body"
jq -e '.status == "unavailable" and .checkpoints == false and .checkpoint_failure.reason == "chain_invalid"' \
  <<<"$tampered_readyz_body" >/dev/null \
  || fail "tampered readiness body did not report chain_invalid: $tampered_readyz_body"

# Now perform a consistent rewrite of event hashes so the chain is internally valid,
# but diverges from custody's signed receipt.
"${PSQL[@]}" -qAtc "
  BEGIN;
  SET LOCAL session_replication_role = replica;
  $consistent_rewrite_sql
  COMMIT;
" >>"$BRING_UP_LOG" 2>&1 || fail "committed consistent rewrite failed"

log "-- docker compose restart backend (internally valid chain with tampered digest)"
"${COMPOSE[@]}" restart backend >>"$BRING_UP_LOG" 2>&1 \
  || fail "backend restart failed"
wait_for_readyz_status 503 60 \
  || fail "backend did not fail readiness on digest mismatch"
rewrite_readyz_body=$(curl -sS "$BACKEND_URL/readyz") \
  || fail "could not read rewrite readyz body"
jq -e '.status == "unavailable" and .checkpoints == false and .checkpoint_failure.reason == "chain_digest_mismatch"' \
  <<<"$rewrite_readyz_body" >/dev/null \
  || fail "rewrite readiness body did not report chain_digest_mismatch: $rewrite_readyz_body"
pass "restart gates refuse to resume on both broken chain and consistent digest mismatch"

# 6. Test custody restart durability: signing key and receipts survive container restart.
log "-- docker compose restart custody"
"${COMPOSE[@]}" restart custody >>"$BRING_UP_LOG" 2>&1 \
  || fail "custody restart failed"
wait_for_service_healthy custody 30 \
  || fail "custody failed to recover healthy after restart"
custody_key_after=$(curl -fsS "$CUSTODY_URL/public-key" | jq -r '.public_key')
[[ "$custody_key_after" == "$custody_key_hex" ]] \
  || fail "custody signing key rotated across restart: $custody_key_after vs $custody_key_hex"
custody_receipts_after=$(curl -fsS "$CUSTODY_URL/receipts")
[[ "$(jq 'length' <<<"$custody_receipts_after")" == "1" ]] \
  || fail "custody receipt lost across restart"
pass "custody key and receipt store survive container restart unchanged"

# 7. Restore the database from the pre-tamper dump; only then may service resume.
# Stop the backend first so its retry loop cannot append during the restore window.
"${COMPOSE[@]}" stop backend >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not stop the backend before the restore"
"${COMPOSE[@]}" exec -T postgres psql -X -q -U mm -d postgres \
  -c "DROP DATABASE market_mate WITH (FORCE);" >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not drop the tampered database"
"${COMPOSE[@]}" exec -T postgres psql -X -q -U mm -d postgres \
  -c "CREATE DATABASE market_mate OWNER mm;" >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not recreate the database"
"${COMPOSE[@]}" exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U mm -d market_mate \
  <"$scratch_dir/pre-tamper.sql" >>"$BRING_UP_LOG" 2>&1 \
  || fail "database restore failed"
log "-- database restored from pre-tamper dump ($dump_bytes bytes)"

restored_head_before=$("${PSQL[@]}" -qAtc "SELECT coalesce(max(chain_position), 0) FROM audit_event;") \
  || fail "could not read restored chain head"

"${COMPOSE[@]}" start backend >>"$BRING_UP_LOG" 2>&1 \
  || fail "backend start after restore failed"
wait_for_readyz_status 200 90 \
  || fail "backend did not resume after a verified restore"
restored_readyz_body=$(curl -fsS "$BACKEND_URL/readyz") \
  || fail "could not read restored readyz body"
jq -e '.status == "ok" and .checkpoints == true' \
  <<<"$restored_readyz_body" >/dev/null \
  || fail "restored readiness body is not healthy: $restored_readyz_body"
pass "restored database: service resumed only after restore verification passed"

restore_replay=$(curl -fsS -X POST "$BACKEND_URL/restore-verification") \
  || fail "restore-verification replay failed"
jq -e '.valid == true and .receipts_checked == 1 and .chain_valid == true' \
  <<<"$restore_replay" >/dev/null \
  || fail "restored replay did not validate the custody receipt: $restore_replay"

restored_events=$("${PSQL[@]}" -qAtc "SELECT max(chain_position) FROM audit_event;") \
  || fail "could not read restored chain head"
[[ "$restored_events" == "$((restored_head_before + 1))" ]] \
  || fail "restored chain should hold the dump head plus restore.verified, found $restored_events"

# 7. A second checkpoint after restore binds the grown chain.
checkpoint_two=$(curl -fsS -X POST "$BACKEND_URL/checkpoints") \
  || fail "second checkpoint failed"
receipt_two=$(jq -r '.receipt' <<<"$checkpoint_two")
audit_position_two=$(jq -r '.audit_chain_position' <<<"$checkpoint_two")
jq -e ".checkpoint_index == 2 and .chain_position == $restored_events" \
  <<<"$receipt_two" >/dev/null \
  || fail "second receipt does not bind the restored chain head: $receipt_two"
final_verification=$(curl -fsS -X POST "$BACKEND_URL/restore-verification") \
  || fail "final restore verification failed"
jq -e '.valid == true and .receipts_checked == 2' \
  <<<"$final_verification" >/dev/null \
  || fail "final verification did not replay both receipts: $final_verification"
pass "second checkpoint binds the grown, restored chain"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson readyz_initial "$readyz_initial" \
  --argjson custody_public_key "$custody_public_key" \
  --argjson receipts_initial "$receipts_initial" \
  --argjson receipt "$receipt" \
  --argjson audit_position_one "$audit_position_one" \
  --argjson mirror_row "$mirror_row" \
  --arg canonical "$canonical" \
  --arg verify_tool "openssl pkeyutl ed25519" \
  --arg verify_output "$(printf '%s' "$openssl_output" | tr '\n' ' ' | tr -s ' ')" \
  --argjson custody_receipts "$custody_receipts_one" \
  --argjson payload_only_probe "$payload_only_probe" \
  --arg digest_after_rewrite "$rewrite_verification" \
  --arg receipt_digest "$expected_digest" \
  --argjson tampered_readyz_body "$(jq -c . <<<"$tampered_readyz_body")" \
  --argjson rewrite_readyz_body "$(jq -c . <<<"$rewrite_readyz_body")" \
  --argjson restored_readyz_body "$(jq -c . <<<"$restored_readyz_body")" \
  --argjson restore_replay "$restore_replay" \
  --argjson dump_bytes "$dump_bytes" \
  --argjson restored_chain_head "$restored_events" \
  --argjson receipt_two "$receipt_two" \
  --argjson audit_position_two "$audit_position_two" \
  --argjson final_verification "$final_verification" \
  '{
    captured_at: $captured_at,
    readyz_initial: $readyz_initial,
    custody_public_key: $custody_public_key,
    receipts_initial: $receipts_initial,
    checkpoint_one: {
      receipt: $receipt,
      audit_chain_position: $audit_position_one,
      database_mirror: $mirror_row,
      independent_verification: {
        canonical: $canonical,
        tool: $verify_tool,
        output: $verify_output
      },
      custody_receipts: $custody_receipts
    },
    tamper_probes: {
      payload_only: $payload_only_probe,
      consistent_rewrite: {
        chain_valid_after_rewrite: true,
        digest_after_rewrite: $digest_after_rewrite,
        receipt_digest: $receipt_digest
      }
    },
    restart_gate: {
      tampered_payload: {
        status: 503,
        sustained: true,
        body: $tampered_readyz_body
      },
      tampered_digest: {
        status: 503,
        body: $rewrite_readyz_body
      },
      restored: {
        status: 200,
        body: $restored_readyz_body
      }
    },
    restore: {
      dump_bytes: $dump_bytes,
      restored_chain_head: $restored_chain_head,
      replay: $restore_replay
    },
    checkpoint_two: {
      receipt: $receipt_two,
      audit_chain_position: $audit_position_two
    },
    final_verification: $final_verification
  }' >"$REPORT" \
  || fail "could not write checkpoint receipt report"

jq -e '
  .readyz_initial.checkpoints == true
  and .custody_public_key.algorithm == "ed25519"
  and .checkpoint_one.receipt.checkpoint_index == 1
  and .checkpoint_one.receipt.chain_position > 0
  and .checkpoint_one.independent_verification.canonical != ""
  and (.checkpoint_one.custody_receipts | length) == 1
  and .tamper_probes.payload_only.valid == false
  and .tamper_probes.consistent_rewrite.chain_valid_after_rewrite == true
  and .tamper_probes.consistent_rewrite.digest_after_rewrite != .tamper_probes.consistent_rewrite.receipt_digest
  and .restart_gate.tampered_payload.status == 503
  and .restart_gate.tampered_payload.body.checkpoints == false
  and .restart_gate.tampered_payload.body.checkpoint_failure.reason == "chain_invalid"
  and .restart_gate.tampered_digest.status == 503
  and .restart_gate.tampered_digest.body.checkpoints == false
  and .restart_gate.tampered_digest.body.checkpoint_failure.reason == "chain_digest_mismatch"
  and .restart_gate.restored.status == 200
  and .restart_gate.restored.body.checkpoints == true
  and .restore.replay.valid == true
  and .checkpoint_two.receipt.checkpoint_index == 2
  and .final_verification.valid == true
  and .final_verification.receipts_checked == 2
' "$REPORT" >/dev/null \
  || fail "checkpoint receipt report does not satisfy the WU-04 evidence schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] \
  || fail "named WU-04 evidence is not retrievable"

pass "valid evidence is retrievable at $REPORT"
log "WU-04 COMPLETE"
