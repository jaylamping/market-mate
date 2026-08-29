#!/usr/bin/env bash
# WU-07 executable acceptance test — security master schema and lifecycle.
# Evidence: security-master integrity report written to evidence/wu-07/.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-07"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/security-master-integrity-report.json"
WU07_PROJECT_NAME="${WU07_COMPOSE_PROJECT_NAME:-market-mate-wu07}"
COMPOSE=(docker compose --project-name "$WU07_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)
FIXTURES="db/fixtures/wu07_security_master_fixtures.sql"

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() {
  printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"
}

fail() {
  log "WU-07 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}

pass() {
  log "WU-07 PASS: $1"
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

require_command docker
require_command jq

log "== WU-07 security master test $(date -u +%FT%TZ) (project: $WU07_PROJECT_NAME) =="

"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose configuration is invalid"

for sibling in market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09; do
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove prior WU-07 Compose state"

log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose bring-up failed"

wait_for_healthy_services 300 \
  || fail "backend, frontend, postgres, and custody did not all reach healthy"
pass "full Compose stack is healthy"

expect_reject() {
  local name="$1"
  local sql="$2"
  if "${PSQL[@]}" -c "$sql" >>"$BRING_UP_LOG" 2>&1; then
    fail "probe $name unexpectedly succeeded; the contract it exercises is not enforced"
  fi
  pass "probe $name blocked as required"
}

FIXTURE_LINEAGE="'{\"source\":\"wu07-fixture\",\"entitlement_version\":\"local-v1\"}'"
RECEIPT="'2026-01-01T00:00:00Z'"

probe_setup() {
  printf '%s\n' \
    "BEGIN;" \
    "INSERT INTO issuer (issuer_id, legal_name, source_lineage, receipt_time, record_environment)" \
    "VALUES ('99999999-0000-0000-0000-000000000001', 'Probe Issuer', $FIXTURE_LINEAGE, $RECEIPT, 'local_research');" \
    "INSERT INTO security (security_id, issuer_id, security_class, source_lineage, receipt_time, record_environment)" \
    "VALUES ('99999999-0000-0000-0000-000000000002', '99999999-0000-0000-0000-000000000001', 'common_stock', $FIXTURE_LINEAGE, $RECEIPT, 'local_research');"
}

# 1. The fixture set loads cleanly and satisfies its structural assertions.
"${COMPOSE[@]}" cp "$FIXTURES" postgres:/tmp/wu07-fixtures.sql \
  >>"$BRING_UP_LOG" 2>&1 || fail "could not copy the fixture set into the postgres container"
fixture_assertions=$("${PSQL[@]}" \
  -c "BEGIN;" \
  -f /tmp/wu07-fixtures.sql \
  -c "SELECT row_to_json(r) FROM (
        SELECT
          (SELECT count(*) FROM issuer) AS issuers,
          (SELECT count(*) FROM security) AS securities,
          (SELECT count(*) FROM exchange_listing) AS listings,
          (SELECT count(*) FROM listing_symbol_alias) AS listing_aliases,
          (SELECT count(*) FROM security_symbol_alias) AS security_aliases,
          (SELECT count(DISTINCT listing_id) FROM listing_symbol_alias WHERE upper(symbol) = 'ACME') AS acme_listing_identities,
          (SELECT count(*) FROM listing_symbol_alias WHERE listing_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc') AS acme_symbol_change_aliases,
          (SELECT upper(symbol) FROM listing_symbol_alias
            WHERE listing_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
              AND valid_from <= '2019-06-01T00:00:00Z'
              AND (valid_to IS NULL OR valid_to > '2019-06-01T00:00:00Z')) AS acme_symbol_at_2019,
          (SELECT upper(symbol) FROM listing_symbol_alias
            WHERE listing_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
              AND valid_from <= '2021-06-01T00:00:00Z'
              AND (valid_to IS NULL OR valid_to > '2021-06-01T00:00:00Z')) AS acme_symbol_at_2021
      ) r;" \
  -c "ROLLBACK;") \
  || fail "security-master fixture set failed to load"
jq -e '
  .issuers == 2
  and .securities == 2
  and .listings == 2
  and .listing_aliases == 3
  and .security_aliases == 3
  and .acme_listing_identities == 2
  and .acme_symbol_change_aliases == 2
  and .acme_symbol_at_2019 == "ACME"
  and .acme_symbol_at_2021 == "ACMX"
' <<<"$fixture_assertions" >/dev/null \
  || fail "fixture structural assertions failed: $fixture_assertions"
pass "fixture set loads; identity-continuous symbol change is two time-bounded aliases on one listing; reuse keeps distinct identities"

# 2. Validity intervals are enforced: an inverted interval is rejected.
expect_reject "interval-inversion" "$(probe_setup)
INSERT INTO security_symbol_alias (
  alias_id, security_id, symbol, source, valid_from, valid_to,
  source_lineage, receipt_time, record_environment
) VALUES (
  '99999999-0000-0000-0000-000000000003',
  '99999999-0000-0000-0000-000000000002', 'PROBE', 'wu07-probe-source',
  '2023-01-01T00:00:00Z', '2022-01-01T00:00:00Z',
  $FIXTURE_LINEAGE, $RECEIPT, 'local_research'
);
ROLLBACK;"

# 3. Overlapping same-source same-symbol aliases are rejected (fail closed).
expect_reject "overlapping-alias" "$(probe_setup)
INSERT INTO security_symbol_alias (
  alias_id, security_id, symbol, source, valid_from, valid_to,
  source_lineage, receipt_time, record_environment
) VALUES (
  '99999999-0000-0000-0000-000000000003',
  '99999999-0000-0000-0000-000000000002', 'PROBE', 'wu07-probe-source',
  '2020-01-01T00:00:00Z', '2022-01-01T00:00:00Z',
  $FIXTURE_LINEAGE, $RECEIPT, 'local_research'
);
INSERT INTO security_symbol_alias (
  alias_id, security_id, symbol, source, valid_from, valid_to,
  source_lineage, receipt_time, record_environment
) VALUES (
  '99999999-0000-0000-0000-000000000004',
  '99999999-0000-0000-0000-000000000002', 'probe', 'wu07-probe-source',
  '2021-01-01T00:00:00Z', '2023-01-01T00:00:00Z',
  $FIXTURE_LINEAGE, $RECEIPT, 'local_research'
);
ROLLBACK;"

# 4. Overlapping listings of one security on one venue are rejected.
expect_reject "overlapping-listing" "$(probe_setup)
INSERT INTO exchange_listing (
  listing_id, security_id, venue, currency, listing_status,
  valid_from, valid_to, source_lineage, receipt_time, record_environment
) VALUES (
  '99999999-0000-0000-0000-000000000003',
  '99999999-0000-0000-0000-000000000002', 'NYSE', 'USD', 'active',
  '2020-01-01T00:00:00Z', NULL,
  $FIXTURE_LINEAGE, $RECEIPT, 'local_research'
);
INSERT INTO exchange_listing (
  listing_id, security_id, venue, currency, listing_status,
  valid_from, valid_to, source_lineage, receipt_time, record_environment
) VALUES (
  '99999999-0000-0000-0000-000000000004',
  '99999999-0000-0000-0000-000000000002', 'NYSE', 'USD', 'active',
  '2021-01-01T00:00:00Z', NULL,
  $FIXTURE_LINEAGE, $RECEIPT, 'local_research'
);
ROLLBACK;"

sequential_tmp=$(mktemp /tmp/wu07.XXXXXX)
trap 'rm -f "$sequential_tmp"' EXIT
{
  printf '%s\n' "$(probe_setup)"
  printf '%s\n' \
    "INSERT INTO security_symbol_alias (alias_id, security_id, symbol, source, valid_from, valid_to, source_lineage, receipt_time, record_environment)" \
    "VALUES ('99999999-0000-0000-0000-000000000003', '99999999-0000-0000-0000-000000000002', 'PROBE', 'wu07-probe-source', '2020-01-01T00:00:00Z', '2022-01-01T00:00:00Z', $FIXTURE_LINEAGE, $RECEIPT, 'local_research');" \
    "INSERT INTO security_symbol_alias (alias_id, security_id, symbol, source, valid_from, valid_to, source_lineage, receipt_time, record_environment)" \
    "VALUES ('99999999-0000-0000-0000-000000000004', '99999999-0000-0000-0000-000000000002', 'PROBE', 'wu07-probe-source', '2023-01-01T00:00:00Z', NULL, $FIXTURE_LINEAGE, $RECEIPT, 'local_research');" \
    "SELECT count(*) FROM security_symbol_alias WHERE upper(symbol) = 'PROBE';" \
    "ROLLBACK;"
} >"$sequential_tmp"
"${COMPOSE[@]}" cp "$sequential_tmp" postgres:/tmp/wu07-sequential.sql \
  >>"$BRING_UP_LOG" 2>&1 || fail "could not copy the sequential probe into the postgres container"
sequential_probe=$("${PSQL[@]}" -f /tmp/wu07-sequential.sql) \
  || fail "sequential same-symbol aliases were rejected; history must be representable"
[[ "$sequential_probe" == "2" ]] \
  || fail "sequential alias probe produced an unexpected count: $sequential_probe"
pass "sequential same-symbol aliases accepted as alias history"

# 6. No identifier is a primary or unique key anywhere in the security master.
pk_shape=$("${PSQL[@]}" -c "SELECT coalesce(json_agg(json_build_object('table', c.relname, 'pk', a.attname)), '[]')
  FROM pg_constraint con
  JOIN pg_class c ON c.oid = con.conrelid
  JOIN unnest(con.conkey) AS k(attnum) ON true
  JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
  WHERE con.contype = 'p'
    AND c.relname IN ('issuer','security','exchange_listing','issuer_symbol_alias','security_symbol_alias','listing_symbol_alias');") \
  || fail "primary key catalog probe failed: $pk_shape"
pk_tables=$("${PSQL[@]}" -c "SELECT count(DISTINCT c.relname)
  FROM pg_constraint con
  JOIN pg_class c ON c.oid = con.conrelid
  WHERE con.contype = 'p'
    AND c.relname IN ('issuer','security','exchange_listing','issuer_symbol_alias','security_symbol_alias','listing_symbol_alias');") \
  || fail "primary key table count probe failed"
[[ "$pk_tables" == "6" ]] \
  || fail "expected all six security-master tables to carry a primary key, found $pk_tables"
jq -e 'length == 6 and all(.[]; .pk | test("_id$")) and ([.[].pk] | index("symbol") | not)' \
  <<<"$pk_shape" >/dev/null \
  || fail "primary key shape is not uuid-id-only: $pk_shape"
pk_unique_symbol=$("${PSQL[@]}" -c "SELECT count(*) FROM pg_index i
  JOIN pg_class c ON c.oid = i.indrelid
  WHERE c.relname IN ('issuer','security','exchange_listing','issuer_symbol_alias','security_symbol_alias','listing_symbol_alias')
    AND i.indisunique
    AND EXISTS (
      SELECT 1 FROM pg_attribute a
      WHERE a.attrelid = c.oid AND a.attnum = ANY (string_to_array(i.indkey::text, ' ')::int2[])
        AND upper(a.attname) = 'SYMBOL'
    );") \
  || fail "unique-index catalog probe failed"
[[ "$pk_unique_symbol" == "0" ]] \
  || fail "an identifier column carries a unique index"
pass "no identifier is a primary or unique key"

# 7. Master entities are append-only: mutation is rejected.
expect_reject "issuer-delete-blocked" "$(probe_setup)
DELETE FROM issuer;
ROLLBACK;"

# 8. Assemble and validate the evidence report.
jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson fixture_assertions "$fixture_assertions" \
  --arg unique_symbol_indexes "$pk_unique_symbol" \
  '{
    captured_at: $captured_at,
    fixture_set: {
      loaded: true,
      issuers: $fixture_assertions.issuers,
      securities: $fixture_assertions.securities,
      listings: $fixture_assertions.listings,
      listing_aliases: $fixture_assertions.listing_aliases,
      security_aliases: $fixture_assertions.security_aliases,
      identity_continuous_symbol_change_represented: (
        $fixture_assertions.acme_symbol_change_aliases == 2
        and $fixture_assertions.acme_symbol_at_2019 == "ACME"
        and $fixture_assertions.acme_symbol_at_2021 == "ACMX"
      ),
      symbol_reuse_keeps_distinct_identities: ($fixture_assertions.acme_listing_identities == 2)
    },
    validity_interval_enforcement: {
      inverted_interval_blocked: true,
      overlapping_alias_blocked: true,
      overlapping_listing_blocked: true,
      sequential_alias_accepted: true
    },
    identifier_discipline: {
      unique_symbol_indexes: ($unique_symbol_indexes | tonumber),
      no_identifier_is_primary_or_unique_key: true
    },
    append_only: {
      issuer_delete_blocked: true
    }
  }' >"$REPORT" \
  || fail "could not write security-master integrity report"

jq -e '
  .fixture_set.loaded == true
  and .fixture_set.issuers == 2
  and .fixture_set.identity_continuous_symbol_change_represented == true
  and .fixture_set.symbol_reuse_keeps_distinct_identities == true
  and .validity_interval_enforcement.inverted_interval_blocked == true
  and .validity_interval_enforcement.overlapping_alias_blocked == true
  and .validity_interval_enforcement.overlapping_listing_blocked == true
  and .validity_interval_enforcement.sequential_alias_accepted == true
  and .identifier_discipline.unique_symbol_indexes == 0
  and .append_only.issuer_delete_blocked == true
' "$REPORT" >/dev/null \
  || fail "integrity report does not satisfy the WU-07 evidence schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" ]] \
  || fail "named WU-07 evidence is not retrievable"

pass "valid evidence is retrievable at $REPORT"
log "WU-07 COMPLETE"
