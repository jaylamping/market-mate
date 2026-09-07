#!/usr/bin/env python3
"""Read-only checkout/tool/runtime inspection. Never dump credentials or Docker env."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(args):
    try:
        result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=20)
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def migration_check(directory, applied):
    local = {}
    names = set()
    for path in sorted(directory.glob("*.sql")):
        match = re.fullmatch(r"([+]?[0-9]+)_([A-Za-z0-9_]+)\.sql", path.name)
        if not match or not 1 <= int(match[1]) <= 2**63 - 1:
            return "fail", f"Invalid source migration filename: {path.name}"
        version, name = int(match[1]), match[2]
        if version in local or name in names:
            return "fail", f"Duplicate source migration version or name: {path.name}"
        try:
            checksum = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError:
            return "fail", f"Unreadable source migration: {path.name}"
        local[version] = (name, checksum)
        names.add(name)
    if not local:
        return "fail", "No source migrations found."
    if sorted(local) != list(range(1, len(local) + 1)):
        return "fail", "Source migration versions must be contiguous from 1."
    mismatches = [str(row["version"]) for row in applied
                  if local.get(row["version"]) != (row["name"], row["checksum"])]
    if mismatches:
        return "fail", "Applied/source migration mismatch at versions: " + ", ".join(mismatches)
    pending = sorted(set(local) - {row["version"] for row in applied})
    if pending:
        return "warn", "Unapplied source migrations: " + ", ".join(map(str, pending))
    return "pass", f"Applied migration bytes match source through version {max(local)}."


def inspect(runtime=False):
    checks = []

    def add(name, state, detail):
        checks.append({"check": name, "status": state, "detail": detail})

    for tool in ["git", "cargo", "node", "npm", "docker", "gh"]:
        if not shutil.which(tool):
            add(tool, "warn" if tool in ["docker", "gh"] else "fail", "Not available on PATH.")
            continue
        version = run([tool, "--version"])
        add(tool, "pass" if version else "warn", version.splitlines()[0] if version else "Installed but version check failed.")
    for name, args in [("branch", ["git", "branch", "--show-current"]),
                       ("commit", ["git", "rev-parse", "HEAD"]),
                       ("working_tree", ["git", "status", "--short"]),
                       ("worktrees", ["git", "worktree", "list", "--porcelain"])]:
        value = run(args)
        add(name, "pass" if value is not None else "fail", value if value else ("Clean or empty." if value == "" else "Unavailable."))
    add("runtime_scope", "pass", "Inspection only. No provider requests, migrations, service starts, policy changes, or Git fetch.")
    if runtime:
        raw = run(["docker", "compose", "ps", "--all", "--format", "json"])
        try:
            containers = json.loads(raw) if raw and raw.startswith("[") else [json.loads(line) for line in (raw or "").splitlines()]
        except (ValueError, TypeError):
            containers = []
        if not containers:
            add("compose", "warn", "No inspectable containers for this Compose project; runtime state is unavailable.")
        for container in containers:
            service = container["Service"]
            healthy = container.get("State") == "running" and container.get("Health") in (None, "", "healthy")
            add("service:" + service, "pass" if healthy else "warn", f"{container.get('State', 'unknown')} / {container.get('Health') or 'no healthcheck'}")
            running = run(["docker", "inspect", "--format", "{{.Image}}", container["ID"]])
            tagged = run(["docker", "image", "inspect", "--format", "{{.Id}}", container["Image"]])
            add("image:" + service, "warn" if not running or not tagged or running != tagged else "pass",
                "Running image differs from tag or could not be compared." if not running or not tagged or running != tagged else "Running image matches local tag; source revision still requires build evidence.")
        if any(c["Service"] == "postgres" and c.get("State") == "running" for c in containers):
            sql = "SELECT coalesce(jsonb_agg(jsonb_build_object('version',version,'name',name,'checksum',checksum) ORDER BY version),'[]'::jsonb) FROM schema_migration"
            raw = run(["docker", "compose", "exec", "-T", "postgres", "psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-U", "mm", "-d", "market_mate", "-c", sql])
            try:
                status, detail = migration_check(ROOT / "db/migrations", json.loads(raw))
                add("migrations", status, detail)
            except (ValueError, TypeError, KeyError):
                add("migrations", "warn", "Migration registry could not be read; no database changes attempted.")
        else:
            add("migrations", "warn", "No running project PostgreSQL; applied migrations are unknown.")
    return {"root": str(ROOT), "checks": checks,
            "status": "fail" if any(c["status"] == "fail" for c in checks) else "warn" if any(c["status"] == "warn" for c in checks) else "pass"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", action="store_true", help="Read project containers and migration registry")
    parser.add_argument("--json", action="store_true", help="Emit a single JSON report")
    args = parser.parse_args()
    report = inspect(args.runtime)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for check in report["checks"]:
            print(f"[{check['status']}] {check['check']}: {check['detail']}")
    raise SystemExit(1 if report["status"] == "fail" else 0)
