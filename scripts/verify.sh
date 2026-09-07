#!/usr/bin/env bash
# Shared checks only: never starts the application or sends provider requests.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
profile="${1:-all}"
if [[ $# -gt 1 ]]; then echo "Usage: bash scripts/verify.sh [all|context|backend|frontend]" >&2; exit 2; fi
context() {
  python3 scripts/check_agent_context.py
  python3 -m unittest discover -s scripts -p 'test_agent_tools.py'
}
backend() {
  cargo test --locked
  cargo fmt --check
}
frontend() {
  npm --prefix frontend run typecheck
  npm --prefix frontend test
  npm --prefix frontend run build
}
case "$profile" in
  context) context ;;
  backend) backend ;;
  frontend) frontend ;;
  all) context; backend; frontend ;;
  *) echo "Usage: bash scripts/verify.sh [all|context|backend|frontend]" >&2; exit 2 ;;
esac
git diff --check
git diff --cached --check
