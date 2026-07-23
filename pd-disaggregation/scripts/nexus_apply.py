#!/usr/bin/env python3
"""Apply an audited NX-OS command file without persisting credentials."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys

import pexpect


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command_file", type=Path)
    parser.add_argument("--host", default="192.168.160.162")
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()

    username = os.environ.get("NEXUS_USERNAME", "")
    password = os.environ.get("NEXUS_PASSWORD", "")
    if not username or not password:
        print("NEXUS_CREDENTIALS_MISSING", file=sys.stderr)
        return 2

    commands = [
        line.strip()
        for line in args.command_file.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("!")
    ]
    if not commands or commands[0] != "configure terminal":
        print("REFUSING_FILE_WITHOUT_CONFIGURE_TERMINAL", file=sys.stderr)
        return 2

    ssh_args = [
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "PreferredAuthentications=password,keyboard-interactive",
        "-o", "PubkeyAuthentication=no",
        f"{username}@{args.host}",
    ]
    child = pexpect.spawn("ssh", ssh_args, encoding="utf-8", timeout=args.timeout)
    state = child.expect([r"(?i)password:", r"# *$", pexpect.EOF, pexpect.TIMEOUT])
    if state == 0:
        child.sendline(password)
        state = child.expect([r"# *$", r"(?i)permission denied", pexpect.EOF, pexpect.TIMEOUT])
        if state != 0:
            print("NEXUS_LOGIN_FAILED", file=sys.stderr)
            return 3
    elif state != 1:
        print("NEXUS_CONNECTION_FAILED", file=sys.stderr)
        return 4

    failed = False
    for command in commands:
        child.sendline(command)
        try:
            child.expect(r"# *$")
        except (pexpect.EOF, pexpect.TIMEOUT):
            print(f"FAILED {command}: prompt timeout", file=sys.stderr)
            failed = True
            break
        output = child.before.replace("\r", "")
        if "% Invalid" in output or "% Incomplete" in output or "ERROR" in output:
            print(f"FAILED {command}:\n{output}", file=sys.stderr)
            failed = True
            break
        print(f"OK {command}")

    if failed:
        child.sendline("end")
    child.sendline("exit")
    child.close(force=True)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
