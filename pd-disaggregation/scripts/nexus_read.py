#!/usr/bin/env python3
"""Collect sanitized, read-only Cisco Nexus state.

Credentials are read only from NEXUS_USERNAME and NEXUS_PASSWORD. They are never
printed or written by this script.
"""

from __future__ import annotations

import argparse
import os
import sys

import pexpect


DEFAULT_COMMANDS = (
    "terminal length 0",
    "show hostname",
    "show version",
    "show module",
    "show interface status",
    "show interface brief",
    "show interface counters errors",
    "show lldp neighbors detail",
    "show mac address-table",
    "show vlan brief",
    "show ip interface brief",
    "show running-config interface",
    "show running-config | section qos",
    "show system qos",
    "show policy-map system type network-qos",
    "show policy-map system type qos",
    "show policy-map system type queuing",
    "show queuing interface",
    "show hardware qos buffer status",
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="192.168.160.162")
    parser.add_argument("--timeout", type=int, default=45)
    parser.add_argument("commands", nargs="*")
    args = parser.parse_args()

    username = os.environ.get("NEXUS_USERNAME", "")
    password = os.environ.get("NEXUS_PASSWORD", "")
    if not username or not password:
        print("NEXUS_CREDENTIALS_MISSING", file=sys.stderr)
        return 2

    ssh_args = [
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "PreferredAuthentications=password,keyboard-interactive",
        "-o",
        "PubkeyAuthentication=no",
        f"{username}@{args.host}",
    ]
    child = pexpect.spawn("ssh", ssh_args, encoding="utf-8", timeout=args.timeout)
    state = child.expect([r"(?i)password:", r"[#>] *$", pexpect.EOF, pexpect.TIMEOUT])
    if state == 0:
        child.sendline(password)
        state = child.expect(
            [r"# *$", r"> *$", r"(?i)permission denied", pexpect.EOF, pexpect.TIMEOUT]
        )
        if state != 0:
            print("NEXUS_LOGIN_FAILED", file=sys.stderr)
            return 3
    elif state != 1:
        print("NEXUS_CONNECTION_FAILED", file=sys.stderr)
        return 4

    # NX-OS may decorate the prompt or omit a leading newline. Matching the
    # terminating privileged-mode marker is more robust than anchoring the
    # hostname while still avoiding command-output pagination prompts.
    prompt = r"# *$"
    commands = tuple(args.commands) or DEFAULT_COMMANDS
    # Explicit command lists must also disable pagination. Without this, a
    # `--More--` prompt can consume the first character of the next command.
    if commands and commands[0] != "terminal length 0":
        commands = ("terminal length 0",) + commands
    for command in commands:
        child.sendline(command)
        try:
            child.expect(prompt)
        except (pexpect.EOF, pexpect.TIMEOUT):
            partial = child.before.replace("\r", "")[-4000:]
            print(f"=== {command} ===\nCOMMAND_FAILED\n{partial}")
            continue
        output = child.before.replace("\r", "")
        lines = output.splitlines()
        if lines and lines[0].strip() == command:
            lines = lines[1:]
        print(f"=== {command} ===")
        print("\n".join(lines).strip())

    child.sendline("exit")
    child.close(force=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
