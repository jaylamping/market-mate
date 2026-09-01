#!/usr/bin/env bash
# WU-48 executable acceptance test — compliance evidence publication.
# Evidence: published file + provenance record on the verified audit chain.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-48"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
REPORT="$EVIDENCE_DIR/compliance-evidence-publication.json"
PROBE_SQL="db/fixtures/wu48_compliance_publication_probe.sql"
CANONICAL="docs/research/self-directed-automated-trading-prohibited-conduct-and-account-rule-inventory.md"
EVIDENCE_COMMIT="bcfcdc2a34f65c7c342326bba9e4f031445a9104"
PUBLICATION_COMMIT="8d430300b8cff9a592d7548055cf42a08acd34c0"
WU48_PROJECT_NAME="${WU48_COMPOSE_PROJECT_NAME:-market-mate-wu48}"
COMPOSE=(docker compose --project-name "$WU48_PROJECT_NAME")
PSQL=("${COMPOSE[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -qAt -U mm -d market_mate)

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$REPORT"

log() { printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"; }
fail() {
  log "WU-48 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}
pass() { log "WU-48 PASS: $1"; }
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
      '{\"source\":\"wu48-acceptance\",\"entitlement_version\":\"compliance-publication-v1\"}'::jsonb,
      now(), 'local_research'
    );
  "
}

require_command docker
require_command jq
require_command openssl
log "== WU-48 Compliance evidence publication test $(date -u +%FT%TZ) (project: $WU48_PROJECT_NAME) =="
[[ -s "$CANONICAL" ]] || fail "canonical published file is missing: $CANONICAL"
git cat-file -e "${EVIDENCE_COMMIT}^{commit}" 2>/dev/null \
  || fail "evidence commit $EVIDENCE_COMMIT is not in this checkout"
git cat-file -e "${PUBLICATION_COMMIT}^{commit}" 2>/dev/null \
  || fail "publication merge commit $PUBLICATION_COMMIT is not in this checkout"
git merge-base --is-ancestor "$EVIDENCE_COMMIT" "$PUBLICATION_COMMIT" \
  || fail "evidence commit is not an ancestor of the publication merge"
parent_count=$(git rev-list --parents -n 1 "$PUBLICATION_COMMIT" | awk '{print NF-1}')
[[ "$parent_count" -ge 2 ]] || fail "publication commit is not a merge (parents=$parent_count)"
pass "canonical file and #55 merge provenance are present"

"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 || fail "Compose configuration is invalid"
for sibling in market-mate market-mate-wu01 market-mate-wu02 market-mate-wu03 market-mate-wu04 market-mate-wu05 market-mate-wu06 market-mate-wu07 market-mate-wu08 market-mate-wu09 market-mate-wu10 market-mate-wu11 market-mate-wu12 market-mate-wu13 market-mate-wu14 market-mate-wu15 market-mate-wu16 market-mate-wu17 market-mate-wu18 market-mate-wu19 market-mate-wu20 market-mate-wu21 market-mate-wu22 market-mate-wu23 market-mate-wu24 market-mate-wu25 market-mate-wu26 market-mate-wu27 market-mate-wu28 market-mate-wu29 market-mate-wu30 market-mate-wu31 market-mate-wu32 market-mate-wu33 market-mate-wu34 market-mate-wu35 market-mate-wu36 market-mate-wu37 market-mate-wu38 market-mate-wu39 market-mate-wu40 market-mate-wu41 market-mate-wu42 market-mate-wu43 market-mate-wu44 market-mate-wu45 market-mate-wu46 market-mate-wu47 market-mate-wu48 market-mate-wu49 market-mate-harden-wu28-31; do
  [[ "$sibling" == "$WU48_PROJECT_NAME" ]] && continue
  docker compose --project-name "$sibling" down --remove-orphans >>"$BRING_UP_LOG" 2>&1 || true
done
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 || fail "could not remove prior WU-48 Compose state"
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
[[ "$migration_head" == "50" ]] || fail "expected migration head 50, got $migration_head"
migration_checksum=$("${PSQL[@]}" -c "SELECT checksum FROM schema_migration WHERE version = 50;") \
  || fail "could not read migration 50 checksum"
migration_schema_head=$("${PSQL[@]}" -c "SELECT schema_head();") \
  || fail "could not read schema head"
migration_fingerprint=$("${PSQL[@]}" -c "SELECT schema_fingerprint();") \
  || fail "could not read schema fingerprint"
[[ "$migration_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "migration 50 checksum is invalid: $migration_checksum"
[[ -n "$migration_schema_head" && -n "$migration_fingerprint" ]] \
  || fail "schema identity evidence is incomplete"
pass "migration 50 and schema identity are recorded"

canonical_b64=$(openssl base64 -A -in "$CANONICAL") \
  || fail "could not encode the canonical published file"
"${COMPOSE[@]}" cp "$PROBE_SQL" postgres:/tmp/wu48-compliance-publication-probe.sql >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not copy the WU-48 probe into the postgres container"
probe_result=$("${PSQL[@]}" \
  -c "BEGIN;" \
  -c "CREATE TEMP TABLE wu48_canonical (content text NOT NULL);" \
  -c "INSERT INTO wu48_canonical (content) SELECT convert_from(decode('${canonical_b64}', 'base64'), 'UTF8');" \
  -f /tmp/wu48-compliance-publication-probe.sql \
  -c "SELECT result FROM wu48_probe_result;" \
  -c "ROLLBACK;") \
  || fail "WU-48 compliance publication probe failed: $probe_result"

for key in \
  unaccepted_publish_fail_closed canonical_path_required squash_refused \
  conclusions_unchanged acceptance_immutable published_on_canonical_path \
  merge_provenance_preserved direct_insert_blocked publication_update_blocked \
  publication_delete_blocked publication_truncate_blocked publication_audited \
  no_authority_grant; do
  [[ "$(jq -r --arg k "$key" '.[$k]' <<<"$probe_result")" == "true" ]] \
    || fail "probe assertion $key failed: $probe_result"
done
[[ "$(jq -r '.canonical_path' <<<"$probe_result")" == "$CANONICAL" ]] \
  || fail "probe canonical path does not match the published file"
[[ "$(jq -r '.evidence_commit' <<<"$probe_result")" == "$EVIDENCE_COMMIT" ]] \
  || fail "probe evidence commit does not match #55 provenance"
[[ "$(jq -r '.publication_commit' <<<"$probe_result")" == "$PUBLICATION_COMMIT" ]] \
  || fail "probe publication commit does not match #55 merge"
pass "accepted compliance evidence publishes to docs/research/ with merge provenance"

public_write_revoked=$("${PSQL[@]}" -c "
  SELECT NOT has_table_privilege('public', 'public.compliance_evidence_publication', 'INSERT')
     AND NOT has_function_privilege(
       'public',
       'accept_compliance_evidence(text,text,text,text,jsonb)',
       'EXECUTE')
     AND NOT has_function_privilege(
       'public',
       'publish_compliance_evidence(text,text,text,text,text,text,jsonb)',
       'EXECUTE');
") || fail "could not inspect public compliance-publication write privileges"
[[ "$public_write_revoked" == "t" ]] || fail "public compliance-publication write privileges were not revoked"
pass "public compliance-publication writes are revoked; workflow guards remain the measured local boundary"

record_payload=$(jq -c '{published_on_canonical_path, merge_provenance_preserved, no_authority_grant, canonical_path, evidence_commit, publication_commit, content_digest}' <<<"$probe_result")
gate_payload=$(jq -c '{unaccepted_publish_fail_closed, canonical_path_required, squash_refused, conclusions_unchanged, acceptance_immutable}' <<<"$probe_result")
guard_payload=$(jq -c '{direct_insert_blocked, publication_update_blocked, publication_delete_blocked, publication_truncate_blocked, publication_audited}' <<<"$probe_result")
chain_record=$(append_audit_event "wu48-record-$(date +%s)" "research.compliance_publication_traced" "$(jq -nc --argjson evidence "$record_payload" '{probe: "wu48_compliance_publication_probe", evidence: $evidence}')") \
  || fail "audit append compliance_publication_traced failed"
chain_gate=$(append_audit_event "wu48-gates-$(date +%s)" "research.compliance_publication_gates_proved" "$(jq -nc --argjson evidence "$gate_payload" '{probe: "wu48_compliance_publication_probe", evidence: $evidence}')") \
  || fail "audit append compliance_publication_gates_proved failed"
chain_guard=$(append_audit_event "wu48-guards-$(date +%s)" "research.compliance_publication_guards_probed" "$(jq -nc --argjson evidence "$guard_payload" '{probe: "wu48_compliance_publication_probe", evidence: $evidence}')") \
  || fail "audit append compliance_publication_guards_probed failed"
[[ "$chain_gate" -gt "$chain_record" && "$chain_guard" -gt "$chain_gate" ]] \
  || fail "audit chain positions did not advance: $chain_record -> $chain_gate -> $chain_guard"
chain_ok=$("${PSQL[@]}" -c "SELECT row_to_json(v) FROM verify_audit_event_chain() v;") \
  || fail "audit chain verification failed"
jq -e '.valid == true' <<<"$chain_ok" >/dev/null || fail "audit chain does not verify: $chain_ok"
pass "publication provenance, gates, and isolated guard probes are recorded on the verified audit chain"

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
  --arg published_file "$CANONICAL" \
  '{
    captured_at: $captured_at,
    migration: {
      head: $migration_head,
      expected_head: 50,
      version: 50,
      name: "compliance_evidence_publication",
      checksum: $migration_checksum,
      schema_head: $migration_schema_head,
      fingerprint: $migration_fingerprint
    },
    published_file: $published_file,
    publication: {
      published_on_canonical_path: $probe.published_on_canonical_path,
      merge_provenance_preserved: $probe.merge_provenance_preserved,
      canonical_path: $probe.canonical_path,
      content_digest: $probe.content_digest,
      evidence_commit: $probe.evidence_commit,
      publication_commit: $probe.publication_commit,
      no_authority_grant: $probe.no_authority_grant
    },
    gates: {
      unaccepted_publish_fail_closed: $probe.unaccepted_publish_fail_closed,
      canonical_path_required: $probe.canonical_path_required,
      squash_refused: $probe.squash_refused,
      conclusions_unchanged: $probe.conclusions_unchanged,
      acceptance_immutable: $probe.acceptance_immutable
    },
    append_only_and_fail_closed: {
      direct_insert_blocked: $probe.direct_insert_blocked,
      publication_update_blocked: $probe.publication_update_blocked,
      publication_delete_blocked: $probe.publication_delete_blocked,
      publication_truncate_blocked: $probe.publication_truncate_blocked,
      publication_audited: $probe.publication_audited,
      public_write_revoked: ($public_write_revoked == "t")
    },
    audit_chain: $chain,
    audit_positions: {
      record: $audit_position_record,
      gates: $audit_position_gates,
      guards: $audit_position_guards
    }
  }' >"$REPORT" || fail "could not write WU-48 evidence report"
jq -e '
  .migration.head == 50
  and .migration.expected_head == 50
  and .migration.name == "compliance_evidence_publication"
  and (.migration.checksum | test("^[0-9a-f]{64}$"))
  and .published_file == "docs/research/self-directed-automated-trading-prohibited-conduct-and-account-rule-inventory.md"
  and .publication.published_on_canonical_path == true
  and .publication.merge_provenance_preserved == true
  and .publication.evidence_commit == "bcfcdc2a34f65c7c342326bba9e4f031445a9104"
  and .publication.publication_commit == "8d430300b8cff9a592d7548055cf42a08acd34c0"
  and .gates.unaccepted_publish_fail_closed == true
  and .gates.conclusions_unchanged == true
  and .append_only_and_fail_closed.direct_insert_blocked == true
  and .append_only_and_fail_closed.public_write_revoked == true
  and .audit_chain.valid == true
  and .audit_positions.gates > .audit_positions.record
  and .audit_positions.guards > .audit_positions.gates
' "$REPORT" >/dev/null || fail "WU-48 evidence report does not satisfy its schema"
[[ -s "$BRING_UP_LOG" && -s "$REPORT" && -s "$CANONICAL" ]] \
  || fail "named WU-48 evidence is not retrievable"
pass "valid evidence is retrievable at $REPORT"
log "WU-48 COMPLETE"
