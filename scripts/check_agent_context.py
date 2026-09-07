#!/usr/bin/env python3
"""Check the portable instruction layer without requiring an IDE or network."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check():
    errors = []
    paths = [ROOT / name for name in ["AGENTS.md", "README.md", "docs/architecture.md", "frontend/AGENTS.md"]]
    for folder in ["docs/agents", "docs/adr", "docs/handoffs"]:
        paths.extend(sorted((ROOT / folder).glob("*.md")))
    for path in paths:
        if not path.is_file():
            errors.append(f"Missing {path.relative_to(ROOT)}")
            continue
        text = path.read_text()
        if re.search(r"/Users/|/home/[A-Za-z][^ /]*/", text):
            errors.append(f"Machine-specific home path: {path.relative_to(ROOT)}")
        for target in re.findall(r"\[[^\]]*\]\(([^)]+)\)", text):
            if "://" in target or target.startswith(("#", "mailto:")):
                continue
            target = target.split("#", 1)[0]
            resolved = (path.parent / target).resolve()
            if not resolved.is_relative_to(ROOT) or not resolved.exists():
                errors.append(f"Broken or external local link in {path.relative_to(ROOT)}: {target}")
    if (ROOT / "AGENTS.md").is_file() and len((ROOT / "AGENTS.md").read_text().splitlines()) > 120:
        errors.append("Root AGENTS.md exceeds the 120-line startup budget")
    for path in (ROOT / "docs/adr").glob("[0-9]*.md"):
        text = path.read_text()
        for required in ["- Status:", "- Date:", "- Decision source:", "- Implementation:", "## Verification", "## Reconsider when"]:
            if required not in text:
                errors.append(f"ADR {path.name} is missing {required}")
    return errors


if __name__ == "__main__":
    errors = check()
    for error in errors:
        print(error)
    print("Agent context checks: " + ("FAIL" if errors else "PASS"))
    raise SystemExit(bool(errors))
