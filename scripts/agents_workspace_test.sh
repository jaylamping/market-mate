#!/usr/bin/env bash
# Run against a disposable database migrated through the current head.
# Both SQL probes roll back; no provider credentials or outbound requests are used.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
: "${DATABASE_URL:?Set DATABASE_URL to an isolated migrated test database}"
test_log_dir="$(mktemp -d)"
trap 'rm -rf "$test_log_dir"' EXIT
for probe in agent_driver agents_workspace; do
  psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -f "db/fixtures/${probe}_probe.sql" > "$test_log_dir/$probe.log"
  if ! grep -Fq 'probe passed' "$test_log_dir/$probe.log"; then
    cat "$test_log_dir/$probe.log"
    exit 1
  fi
  printf '%s: passed\n' "$probe"
done
