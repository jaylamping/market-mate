#!/usr/bin/env bash
# WU-01 executable acceptance test — Compose skeleton and Postgres baseline.
# Verifies bring-up health, pgvector installation without use, and volume persistence.
# Evidence: bring-up log + health snapshot written to evidence/wu-01/.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

EVIDENCE_DIR="evidence/wu-01"
BRING_UP_LOG="$EVIDENCE_DIR/bring-up.log"
HEALTH_SNAPSHOT="$EVIDENCE_DIR/health-snapshot.json"
POSTGRES_DATA_PATH="/var/lib/postgresql/data"
WU01_PROJECT_NAME="${WU01_COMPOSE_PROJECT_NAME:-market-mate-wu01}"
COMPOSE=(docker compose --project-name "$WU01_PROJECT_NAME")

mkdir -p "$EVIDENCE_DIR"
: > "$BRING_UP_LOG"
rm -f "$HEALTH_SNAPSHOT"

log() {
  printf '%s\n' "$1" | tee -a "$BRING_UP_LOG"
}

fail() {
  log "WU-01 FAIL: $1"
  "${COMPOSE[@]}" ps --all >>"$BRING_UP_LOG" 2>&1 || true
  "${COMPOSE[@]}" logs --no-color >>"$BRING_UP_LOG" 2>&1 || true
  exit 1
}

pass() {
  log "WU-01 PASS: $1"
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

require_command curl
require_command docker
require_command jq

log "== WU-01 bring-up test $(date -u +%FT%TZ) (project: $WU01_PROJECT_NAME) =="

"${COMPOSE[@]}" config --quiet >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose configuration is invalid"

# Clean only the isolated WU-01 test project and its named test volume.
"${COMPOSE[@]}" down -v --remove-orphans >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove prior WU-01 Compose state"

log "-- docker compose up -d --build"
"${COMPOSE[@]}" up -d --build >>"$BRING_UP_LOG" 2>&1 \
  || fail "Compose bring-up failed"

# 1. All three services reach healthy and their real readiness probes pass.
wait_for_healthy_services 120 \
  || fail "backend, frontend, and postgres did not all reach healthy"
pass "backend, frontend, and postgres all healthy"

backend_health=$(curl -fsS http://127.0.0.1:8080/healthz) \
  || fail "backend /healthz is unreachable"
backend_ready=$(curl -fsS http://127.0.0.1:8080/readyz) \
  || fail "backend /readyz database readiness is unavailable"
frontend_health=$(curl -fsS http://127.0.0.1:3000/api/health) \
  || fail "frontend /api/health is unreachable"

jq -e '.status == "ok" and .service == "backend" and .environment == "local-research"' \
  <<<"$backend_health" >/dev/null \
  || fail "backend /healthz returned an invalid payload"
jq -e '.status == "ok" and .service == "backend" and .database == true and .migrations == true' \
  <<<"$backend_ready" >/dev/null \
  || fail "backend /readyz returned an invalid payload"
jq -e '.status == "ok" and .service == "frontend"' \
  <<<"$frontend_health" >/dev/null \
  || fail "frontend /api/health returned an invalid payload"
pass "host-level health and readiness payloads are valid"

# Local Research must never publish the platform on a non-loopback interface.
non_loopback_publishers=$("${COMPOSE[@]}" ps --format json \
  | jq -r '.Publishers[]? | select(.PublishedPort != 0 and .URL != "127.0.0.1" and .URL != "::1") | "\(.URL):\(.PublishedPort)"')
[[ -z "$non_loopback_publishers" ]] \
  || fail "services publish beyond localhost: $non_loopback_publishers"
pass "all published service ports are localhost-bound"

# 2. pgvector is installed and unused; control tables from migrate-on-startup are allowed.
pgvector_version=$("${COMPOSE[@]}" exec -T postgres \
  psql -U mm -d market_mate -tAc \
  "SELECT extversion FROM pg_extension WHERE extname = 'vector'")
[[ -n "$pgvector_version" ]] || fail "pgvector extension is not installed"

vector_column_count=$("${COMPOSE[@]}" exec -T postgres \
  psql -U mm -d market_mate -tAc \
  "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND udt_name IN ('vector', 'halfvec', 'sparsevec');")
vector_index_count=$("${COMPOSE[@]}" exec -T postgres \
  psql -U mm -d market_mate -tAc \
  "SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexdef ILIKE '%vector%';")
control_table_count=$("${COMPOSE[@]}" exec -T postgres \
  psql -U mm -d market_mate -tAc \
  "SELECT count(*) FROM schema_object WHERE kind = 'control';")
evidence_table_count=$("${COMPOSE[@]}" exec -T postgres \
  psql -U mm -d market_mate -tAc \
  "SELECT count(*) FROM schema_object WHERE kind = 'evidence';")

[[ "$vector_column_count" == "0" ]] \
  || fail "expected zero vector-typed columns at baseline, found $vector_column_count"
[[ "$vector_index_count" == "0" ]] \
  || fail "expected zero vector indexes at baseline, found $vector_index_count"
[[ "$control_table_count" -ge 2 ]] \
  || fail "expected migrate-on-startup control tables, found $control_table_count"
[[ "$evidence_table_count" == "0" ]] \
  || fail "expected zero evidence tables at baseline, found $evidence_table_count"
pass "pgvector installed, unused, and only control tables registered"

# 3. Named-volume state survives SIGKILL and Compose restart of the same container.
# Host `docker kill` is an operator stop, so unless-stopped will not auto-start;
# the policy still covers process crashes and daemon reboot.
declared_volumes=$("${COMPOSE[@]}" config --volumes)
grep -qx 'pgdata' <<<"$declared_volumes" \
  || fail "Compose does not declare the pgdata named volume"
restart_policy=$("${COMPOSE[@]}" config \
  | awk '/^  postgres:/{p=1} p && /restart:/{print $2; exit}')
[[ "$restart_policy" == "unless-stopped" ]] \
  || fail "postgres restart policy is '$restart_policy', expected unless-stopped"

postgres_container=$("${COMPOSE[@]}" ps -q postgres)
[[ -n "$postgres_container" ]] || fail "PostgreSQL container ID is unavailable"
postgres_volume=$(docker inspect --format \
  "{{range .Mounts}}{{if eq .Destination \"$POSTGRES_DATA_PATH\"}}{{.Name}}{{end}}{{end}}" \
  "$postgres_container")
[[ -n "$postgres_volume" ]] \
  || fail "PostgreSQL data directory is not backed by a named volume"

"${COMPOSE[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U mm -d market_mate -q \
  -c "CREATE TABLE _wu01_persistence_probe (id integer PRIMARY KEY, note text NOT NULL);
      INSERT INTO _wu01_persistence_probe VALUES (1, 'survive');
      INSERT INTO schema_object (table_name, kind) VALUES ('_wu01_persistence_probe', 'control');" \
  >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not seed the persistence probe"

docker kill --signal KILL "$postgres_container" >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not SIGKILL PostgreSQL"
crash_exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$postgres_container")
[[ "$crash_exit_code" == "137" ]] \
  || fail "PostgreSQL crash did not record SIGKILL exit code 137 (found $crash_exit_code)"

docker start "$postgres_container" >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not start the same PostgreSQL container after SIGKILL"
wait_for_healthy_services 60 \
  || fail "all services did not recover to healthy after the PostgreSQL crash"

restarted_postgres_container=$("${COMPOSE[@]}" ps -q postgres)
restarted_postgres_volume=$(docker inspect --format \
  "{{range .Mounts}}{{if eq .Destination \"$POSTGRES_DATA_PATH\"}}{{.Name}}{{end}}{{end}}" \
  "$restarted_postgres_container")
[[ "$restarted_postgres_volume" == "$postgres_volume" ]] \
  || fail "Compose did not reattach the original PostgreSQL named volume"
[[ "$restarted_postgres_container" == "$postgres_container" ]] \
  || fail "PostgreSQL container identity changed across restart"

persistence_probe=$("${COMPOSE[@]}" exec -T postgres \
  psql -U mm -d market_mate -tAc \
  "SELECT note FROM _wu01_persistence_probe WHERE id = 1;")
[[ "$persistence_probe" == "survive" ]] \
  || fail "PostgreSQL state did not survive SIGKILL and Compose restart"

"${COMPOSE[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U mm -d market_mate -q \
  -c "DROP TABLE _wu01_persistence_probe;
      DELETE FROM schema_object WHERE table_name = '_wu01_persistence_probe';" \
  >>"$BRING_UP_LOG" 2>&1 \
  || fail "could not remove the persistence probe"
pass "named-volume state survived PostgreSQL SIGKILL and Compose restart of the same container"

# 4. Produce a valid, named, retrievable health snapshot.
evidence_table_count=$("${COMPOSE[@]}" exec -T postgres \
  psql -U mm -d market_mate -tAc \
  "SELECT count(*) FROM schema_object WHERE kind = 'evidence';")
[[ "$evidence_table_count" == "0" ]] \
  || fail "persistence probe cleanup left $evidence_table_count evidence tables"

backend_health=$(curl -fsS http://127.0.0.1:8080/healthz) \
  || fail "backend /healthz did not recover after the PostgreSQL crash"
backend_ready=$(curl -fsS http://127.0.0.1:8080/readyz) \
  || fail "backend /readyz did not recover after the PostgreSQL crash"
frontend_health=$(curl -fsS http://127.0.0.1:3000/api/health) \
  || fail "frontend /api/health did not recover after the PostgreSQL crash"
backend_user=$(docker inspect --format '{{.Config.User}}' \
  "$("${COMPOSE[@]}" ps -q backend)")
services=$("${COMPOSE[@]}" ps --format json \
  | jq -s '[.[] | {service: .Service, state: .State, health: .Health}]')

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --argjson services "$services" \
  --argjson backend_healthz "$backend_health" \
  --argjson backend_readyz "$backend_ready" \
  --argjson frontend_health "$frontend_health" \
  --arg pgvector_version "$pgvector_version" \
  --argjson vector_column_count "$vector_column_count" \
  --argjson vector_index_count "$vector_index_count" \
  --argjson control_table_count "$control_table_count" \
  --argjson evidence_table_count "$evidence_table_count" \
  --arg named_volume "$postgres_volume" \
  --argjson crash_exit_code "$crash_exit_code" \
  --arg restart_policy "$restart_policy" \
  --arg persistence_probe "$persistence_probe" \
  --arg backend_user "$backend_user" \
  '{
    captured_at: $captured_at,
    services: $services,
    backend_healthz: $backend_healthz,
    backend_readyz: $backend_readyz,
    frontend_health: $frontend_health,
    backend_user: $backend_user,
    postgres: {
      pgvector_version: $pgvector_version,
      vector_column_count: $vector_column_count,
      vector_index_count: $vector_index_count,
      control_table_count: $control_table_count,
      evidence_table_count: $evidence_table_count,
      named_volume: $named_volume,
      crash_exit_code: $crash_exit_code,
      restart_policy: $restart_policy,
      persistence_probe: $persistence_probe
    }
  }' >"$HEALTH_SNAPSHOT" \
  || fail "could not write the health snapshot"

jq -e '
  (.services | length) == 3
  and all(.services[]; .state == "running" and .health == "healthy")
  and .backend_healthz.status == "ok"
  and .backend_healthz.service == "backend"
  and .backend_healthz.environment == "local-research"
  and .backend_readyz.status == "ok"
  and .backend_readyz.database == true
  and .backend_readyz.migrations == true
  and .frontend_health.status == "ok"
  and .frontend_health.service == "frontend"
  and .backend_user == "app"
  and .postgres.pgvector_version != ""
  and .postgres.vector_column_count == 0
  and .postgres.vector_index_count == 0
  and .postgres.control_table_count >= 2
  and .postgres.evidence_table_count == 0
  and .postgres.named_volume != ""
  and .postgres.crash_exit_code == 137
  and .postgres.restart_policy == "unless-stopped"
  and .postgres.persistence_probe == "survive"
' "$HEALTH_SNAPSHOT" >/dev/null \
  || fail "health snapshot does not satisfy the WU-01 evidence schema"
[[ -s "$BRING_UP_LOG" && -s "$HEALTH_SNAPSHOT" ]] \
  || fail "named WU-01 evidence is not retrievable"

"${COMPOSE[@]}" ps >>"$BRING_UP_LOG" 2>&1
pass "valid evidence is retrievable at $BRING_UP_LOG and $HEALTH_SNAPSHOT"
log "WU-01 COMPLETE"
