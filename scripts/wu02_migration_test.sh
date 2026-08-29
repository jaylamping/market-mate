#!/usr/bin/env bash
# WU-02 executable acceptance test — migration tooling and schema conventions.
# Evidence: migration run manifest written to evidence/wu-02/.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-02"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
MANIFEST="$EVIDENCE_DIR/migration-run-manifest.json"
WU02_PROJECT_NAME="${WU02_COMPOSE_PROJECT_NAME:-market-mate-wu02}"
COMPOSE=(docker compose --project-name "$WU02_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U mm)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$MANIFEST"

log() {
  printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"
}

fail() {
  log "WU-02 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}

pass() {
  log "WU-02 PASS: $1"
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
      && " $healthy " == *" postgres "* ]]; then
      return 0
    fi
    sleep 2
  done

  return 1
}

schema_state() {
  local database="$1"
  "${PSQL[@]}" -d "$database" -Atc "
    SELECT json_build_object(
      'head_version', (SELECT max(version) FROM schema_migration),
      'applied', (SELECT coalesce(json_agg(json_build_object(
          'version', version,
          'name', name,
          'checksum', checksum
        ) ORDER BY version), '[]'::json) FROM schema_migration),
      'schema_head', schema_head(),
      'fingerprint', schema_fingerprint(),
      'evidence_tables', (SELECT coalesce(json_agg(table_name ORDER BY table_name), '[]'::json)
                          FROM schema_object WHERE kind = 'evidence')
    );
  "
}

require_command curl
require_command docker
require_command jq

log "== WU-02 migration test $(date -u +%FT%TZ) (project: $WU02_PROJECT_NAME) =="

"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose configuration is invalid"

# Isolate from a leftover WU-01 stack that publishes the same localhost ports.
docker compose --project-name market-mate-wu01 down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true

"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove prior WU-02 Compose state"

log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose bring-up failed"

wait_for_healthy_services 120 \
  || fail "backend, frontend, and postgres did not all reach healthy"
pass "backend, frontend, and postgres all healthy after migrate-on-startup"

backend_ready=$(curl -fsS http://127.0.0.1:8080/readyz) \
  || fail "backend /readyz is unavailable"
jq -e '.status == "ok" and .database == true and .migrations == true' \
  <<<"$backend_ready" >/dev/null \
  || fail "backend /readyz is not migration-ready: $backend_ready"
pass "readiness includes applied migrations"

first_state=$(schema_state market_mate) \
  || fail "could not read schema state after first apply"
jq -e '.head_version == 2 and (.applied | length) == 2 and .schema_head != "" and .fingerprint != "" and (.evidence_tables | length) == 0' \
  <<<"$first_state" >/dev/null \
  || fail "first apply did not reach expected head: $first_state"
pass "first apply reached schema head 2"

second_apply=$("${COMPOSE[@]}" exec -T backend backend migrate) \
  || fail "second migrate invocation failed"
jq -e '.noop == true and .head_version == 2 and (.applied_versions | length) == 0' \
  <<<"$second_apply" >/dev/null \
  || fail "second apply was not a no-op: $second_apply"
second_state=$(schema_state market_mate) \
  || fail "could not read schema state after second apply"
[[ "$(jq -S . <<<"$first_state")" == "$(jq -S . <<<"$second_state")" ]] \
  || fail "second apply mutated schema state"
pass "second apply is a no-op"

"${PSQL[@]}" -d postgres -c "CREATE DATABASE wu02_fresh;" >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not create wu02_fresh"
fresh_apply=$("${COMPOSE[@]}" exec -T \
  -e DATABASE_URL=postgres://mm:local-only@postgres:5432/wu02_fresh \
  backend backend migrate) \
  || fail "fresh-database migrate failed"
jq -e '.noop == false and .head_version == 2 and (.applied_versions == [1, 2])' \
  <<<"$fresh_apply" >/dev/null \
  || fail "fresh database did not apply versions 1 and 2: $fresh_apply"
fresh_state=$(schema_state wu02_fresh) \
  || fail "could not read fresh schema state"
[[ "$(jq -c '{head: .schema_head, fp: .fingerprint}' <<<"$first_state")" \
   == "$(jq -c '{head: .schema_head, fp: .fingerprint}' <<<"$fresh_state")" ]] \
  || fail "fresh database did not reach the same head as the first apply"
pass "fresh database reaches head deterministically"

"${PSQL[@]}" -d wu02_fresh -c "
BEGIN;
CREATE TABLE wu02_evidence_ok (
  id bigint PRIMARY KEY,
  source_lineage jsonb NOT NULL,
  receipt_time timestamptz NOT NULL,
  record_environment record_environment NOT NULL,
  CHECK (source_lineage_is_valid(source_lineage))
);
SELECT register_evidence_table('wu02_evidence_ok');
INSERT INTO wu02_evidence_ok VALUES (
  1,
  '{\"source\":\"edgar\",\"entitlement_version\":\"v1\"}'::jsonb,
  now(),
  'local_research'
);
ROLLBACK;
" >>"$BRING_UP_LOG" 2>&1 \
  || fail "registering a conforming evidence table failed"
conventions_ok=ok

conventions_bad_output=$("${PSQL[@]}" -d wu02_fresh -Atc "
BEGIN;
CREATE TABLE wu02_evidence_bad (id bigint PRIMARY KEY);
SELECT register_evidence_table('wu02_evidence_bad');
ROLLBACK;
" 2>&1 || true)
grep -q 'does not satisfy schema conventions' <<<"$conventions_bad_output" \
  || fail "nonconforming evidence table did not fail closed: $conventions_bad_output"

defaults_output=$("${PSQL[@]}" -d wu02_fresh -Atc "
BEGIN;
CREATE TABLE wu02_evidence_defaults (
  id bigint PRIMARY KEY,
  source_lineage jsonb NOT NULL DEFAULT '{}'::jsonb,
  receipt_time timestamptz NOT NULL DEFAULT now(),
  record_environment record_environment NOT NULL DEFAULT 'local_research'
);
SELECT register_evidence_table('wu02_evidence_defaults');
ROLLBACK;
" 2>&1 || true)
grep -q 'invents provenance via defaults' <<<"$defaults_output" \
  || fail "provenance defaults did not fail closed: $defaults_output"

lineage_output=$("${PSQL[@]}" -d wu02_fresh -Atc "
BEGIN;
CREATE TABLE wu02_evidence_lineage (
  id bigint PRIMARY KEY,
  source_lineage jsonb NOT NULL,
  receipt_time timestamptz NOT NULL,
  record_environment record_environment NOT NULL
);
SELECT register_evidence_table('wu02_evidence_lineage');
INSERT INTO wu02_evidence_lineage VALUES (1, '{}'::jsonb, now(), 'local_research');
ROLLBACK;
" 2>&1 || true)
grep -qi 'source_lineage_valid\|source_lineage_is_valid\|check constraint' <<<"$lineage_output" \
  || fail "missing source_lineage CHECK did not fail closed: $lineage_output"
pass "schema conventions require lineage CHECK, reject defaults, and reject incomplete tables"

scratch_dir="$(pwd)/$EVIDENCE_DIR/scratch"
rm -rf "$scratch_dir"
mkdir -p "$scratch_dir/ooo" "$scratch_dir/checksum" "$scratch_dir/unregistered"
trap 'rm -rf "$scratch_dir"' EXIT

cp db/migrations/0001_schema_conventions.sql "$scratch_dir/ooo/"
printf '%s\n' 'SELECT 1;' >"$scratch_dir/ooo/0003_gap.sql"
"${PSQL[@]}" -d postgres -c "CREATE DATABASE wu02_ooo;" >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not create wu02_ooo"
set +e
ooo_output=$("${COMPOSE[@]}" run --rm --no-deps -T \
  -e DATABASE_URL=postgres://mm:local-only@postgres:5432/wu02_ooo \
  -v "$scratch_dir/ooo:/migrations:ro" \
  backend backend migrate --from-dir /migrations 2>&1)
ooo_status=$?
set -e
[[ "$ooo_status" -ne 0 ]] || fail "out-of-order migration did not fail closed: $ooo_output"
grep -qi 'failed closed' <<<"$ooo_output" \
  || fail "out-of-order failure did not fail closed: $ooo_output"
ooo_table=$("${PSQL[@]}" -d wu02_ooo -Atc \
  "SELECT to_regclass('public.schema_migration') IS NOT NULL;") \
  || fail "could not inspect wu02_ooo after out-of-order attempt"
[[ "$ooo_table" == "f" ]] \
  || fail "out-of-order attempt still created schema_migration"
pass "out-of-order migration fails closed"

cp db/migrations/*.sql "$scratch_dir/checksum/"
printf '\n-- checksum probe\n' >>"$scratch_dir/checksum/0001_schema_conventions.sql"
head_before=$(jq -r '.schema_head' <<<"$fresh_state")
set +e
checksum_output=$("${COMPOSE[@]}" run --rm --no-deps -T \
  -e DATABASE_URL=postgres://mm:local-only@postgres:5432/wu02_fresh \
  -v "$scratch_dir/checksum:/migrations:ro" \
  backend backend migrate --from-dir /migrations 2>&1)
checksum_status=$?
set -e
[[ "$checksum_status" -ne 0 ]] \
  || fail "checksum mismatch did not fail closed: $checksum_output"
grep -qi 'checksum mismatch' <<<"$checksum_output" \
  || fail "checksum mismatch did not fail closed: $checksum_output"
head_after=$("${PSQL[@]}" -d wu02_fresh -Atc "SELECT schema_head();")
[[ "$head_before" == "$head_after" ]] \
  || fail "checksum mismatch mutated schema head"
pass "checksum mismatch of an applied file fails closed"

cp db/migrations/*.sql "$scratch_dir/unregistered/"
printf '%s\n' 'CREATE TABLE sneak (id integer PRIMARY KEY);' \
  >"$scratch_dir/unregistered/0003_unregistered.sql"
"${PSQL[@]}" -d postgres -c "CREATE DATABASE wu02_unreg;" >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not create wu02_unreg"
set +e
unreg_output=$("${COMPOSE[@]}" run --rm --no-deps -T \
  -e DATABASE_URL=postgres://mm:local-only@postgres:5432/wu02_unreg \
  -v "$scratch_dir/unregistered:/migrations:ro" \
  backend backend migrate --from-dir /migrations 2>&1)
unreg_status=$?
set -e
[[ "$unreg_status" -ne 0 ]] \
  || fail "unregistered public table did not fail closed: $unreg_output"
grep -q 'not registered in schema_object' <<<"$unreg_output" \
  || fail "unregistered public table did not fail closed: $unreg_output"
unreg_head=$("${PSQL[@]}" -d wu02_unreg -Atc "SELECT coalesce(max(version), 0) FROM schema_migration;")
[[ "$unreg_head" == "2" ]] \
  || fail "unregistered table apply did not roll back version 3 (head=$unreg_head)"
pass "unregistered public tables fail closed inside the migration transaction"

pgvector_version=$("${PSQL[@]}" -d market_mate -Atc \
  "SELECT extversion FROM pg_extension WHERE extname = 'vector'")
vector_column_count=$("${PSQL[@]}" -d market_mate -Atc \
  "SELECT count(*) FROM information_schema.columns
   WHERE table_schema = 'public' AND udt_name IN ('vector', 'halfvec', 'sparsevec');")
[[ -n "$pgvector_version" ]] || fail "pgvector extension is not installed"
[[ "$vector_column_count" == "0" ]] || fail "vector usage appeared in WU-02"

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson first_apply "$first_state" \
  --argjson second_apply "$second_apply" \
  --argjson second_state "$second_state" \
  --argjson fresh_apply "$fresh_apply" \
  --argjson fresh_state "$fresh_state" \
  --arg conventions_ok "$conventions_ok" \
  --arg ooo_status "$ooo_status" \
  --arg ooo_output "$ooo_output" \
  --arg checksum_status "$checksum_status" \
  --arg checksum_output "$checksum_output" \
  --arg unreg_status "$unreg_status" \
  --arg unreg_output "$unreg_output" \
  --arg unreg_head "$unreg_head" \
  --arg pgvector_version "$pgvector_version" \
  --argjson vector_column_count "$vector_column_count" \
  '{
    captured_at: $captured_at,
    first_apply: $first_apply,
    second_apply: $second_apply,
    second_state: $second_state,
    fresh_apply: $fresh_apply,
    fresh_state: $fresh_state,
    conventions: {
      conforming_register: $conventions_ok,
      nonconforming_failed_closed: true,
      defaults_failed_closed: true,
      empty_lineage_failed_closed: true,
      unregistered_failed_closed: true
    },
    out_of_order: {
      exit_status: ($ooo_status | tonumber),
      failed_closed: true,
      output: $ooo_output
    },
    checksum_mismatch: {
      exit_status: ($checksum_status | tonumber),
      failed_closed: true,
      output: $checksum_output
    },
    unregistered: {
      exit_status: ($unreg_status | tonumber),
      rolled_back_to: ($unreg_head | tonumber),
      output: $unreg_output
    },
    postgres: {
      pgvector_version: $pgvector_version,
      vector_column_count: $vector_column_count
    }
  }' >"$MANIFEST" \
  || fail "could not write the migration run manifest"

jq -e '
  .first_apply.head_version == 2
  and .second_apply.noop == true
  and .fresh_apply.applied_versions == [1, 2]
  and .first_apply.schema_head == .second_state.schema_head
  and .first_apply.schema_head == .fresh_state.schema_head
  and .first_apply.fingerprint == .fresh_state.fingerprint
  and .conventions.conforming_register == "ok"
  and .conventions.nonconforming_failed_closed == true
  and .conventions.defaults_failed_closed == true
  and .conventions.empty_lineage_failed_closed == true
  and .conventions.unregistered_failed_closed == true
  and .out_of_order.exit_status != 0
  and .checksum_mismatch.exit_status != 0
  and .unregistered.exit_status != 0
  and .unregistered.rolled_back_to == 2
  and .postgres.vector_column_count == 0
' "$MANIFEST" >/dev/null \
  || fail "migration run manifest does not satisfy the WU-02 evidence schema"
[[ -s "$MANIFEST" ]] || fail "named WU-02 evidence is not retrievable"

pass "valid evidence is retrievable at $MANIFEST"
log "WU-02 COMPLETE"
