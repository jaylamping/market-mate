#!/usr/bin/env python3
"""Store Paper credentials through stdin in the connector's private Docker volume."""
import getpass
import json
from pathlib import Path
import re
import subprocess
import sys


def main():
    if not sys.stdin.isatty():
        sys.exit("Run this command in an interactive terminal; credentials must not be command arguments.")
    print("Use keys from Alpaca's PAPER account. Input is hidden and not written to the repository.")
    key_id = getpass.getpass("Paper API key ID: ").strip()
    secret_key = getpass.getpass("Paper secret key: ").strip()
    if not all(re.fullmatch(r"[A-Za-z0-9_-]{1,512}", value) for value in (key_id, secret_key)):
        sys.exit("Invalid or empty credentials. Nothing was saved.")
    result = subprocess.run(
        ["docker", "compose", "run", "--rm", "--no-deps", "-T", "paper-credentials"],
        cwd=Path(__file__).resolve().parents[1],
        input=json.dumps({"key_id": key_id, "secret_key": secret_key}).encode(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode:
        sys.exit("Could not store credentials. Start Docker and build the paper-connector service, then retry.")
    print("Paper credentials saved privately in Docker. Refresh http://localhost:3000/paper after 5 seconds.")


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        sys.exit("\nCancelled. No credentials were submitted.")
