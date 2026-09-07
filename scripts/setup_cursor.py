#!/usr/bin/env python3
"""Store Cursor credentials through stdin in the connector's private Docker volume."""
import getpass
import json
from pathlib import Path
import re
import subprocess
import sys


def main():
    if not sys.stdin.isatty():
        sys.exit("Run this command in an interactive terminal; credentials must not be command arguments.")
    print("Use a dedicated Cursor API key. Input is hidden and not written to the repository.")
    api_key = getpass.getpass("Cursor API key: ").strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,512}", api_key):
        sys.exit("Invalid or empty credentials. Nothing was saved.")
    result = subprocess.run(
        ["docker", "compose", "run", "--rm", "--no-deps", "-T", "cursor-credentials"],
        cwd=Path(__file__).resolve().parents[1],
        input=json.dumps({"api_key": api_key}).encode(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode:
        sys.exit("Could not store credentials. Start Docker and build the cursor-connector service, then retry.")
    print("Cursor credentials saved privately in Docker. Refresh http://localhost:3000/system#integrations after 5 seconds.")


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        sys.exit("\nCancelled. No credentials were submitted.")
