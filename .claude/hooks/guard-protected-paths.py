#!/usr/bin/env python3
"""PreToolUse guard for repository policy in AGENTS.md.

Refuses two classes of agent file access that the shared guidance forbids but
nothing else enforces:

1. Writes into `vendor/atsim`, the fixed upstream review snapshot verified by
   `UPSTREAM-SHA256.json`. Reads stay allowed; the snapshot exists to be read.
2. Reads or writes of real private data: the Application Support workspace,
   a configured vault mirror, and Codex authentication files.

Blocks with exit status 2 so the reason is fed back to the agent.
"""

import json
import os
import sys

WRITE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
READ_TOOLS = {"Read"}

VENDOR_OVERRIDE = "ALLOW_VENDOR_SNAPSHOT_UPDATE"


def resolved_target(payload):
    tool_input = payload.get("tool_input") or {}
    raw = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not isinstance(raw, str) or not raw:
        return ""
    path = os.path.expanduser(raw)
    if not os.path.isabs(path):
        path = os.path.join(payload.get("cwd") or os.getcwd(), path)
    return os.path.realpath(path)


def inside(child, parent):
    parent = os.path.realpath(os.path.expanduser(parent))
    return child == parent or child.startswith(parent + os.sep)


def private_roots():
    roots = [os.path.expanduser("~/Library/Application Support/Nav Center")]
    vault = os.environ.get("NAV_CENTER_VAULT_DIR")
    if vault:
        roots.append(vault)
    return roots


def deny(reason):
    sys.stderr.write(reason + "\n")
    sys.exit(2)


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        return 0

    tool = payload.get("tool_name") or ""
    if tool not in WRITE_TOOLS and tool not in READ_TOOLS:
        return 0

    target = resolved_target(payload)
    if not target:
        return 0

    project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or os.getcwd()
    project_dir = os.path.realpath(project_dir)

    for root in private_roots():
        if inside(target, root):
            deny(
                "Blocked by .claude/hooks/guard-protected-paths.py: "
                f"{target} is real private workspace or vault data. AGENTS.md requires "
                "synthetic fixtures and disposable workspaces. Use a temporary directory "
                "with NAV_CENTER_WORKSPACE_ROOT instead."
            )

    codex_dir = os.path.realpath(os.path.expanduser("~/.codex"))
    base = os.path.basename(target).lower()
    if inside(target, codex_dir) and ("auth" in base or "credential" in base or base.endswith(".pem")):
        deny(
            "Blocked by .claude/hooks/guard-protected-paths.py: "
            f"{target} is a Codex authentication file. AGENTS.md forbids reading account "
            "credentials. Use the stubbed bridge fixtures in Tests/NavCenterTests instead."
        )

    vendor_snapshot = os.path.join(project_dir, "vendor", "atsim")
    if tool in WRITE_TOOLS and inside(target, vendor_snapshot):
        if os.path.exists(os.path.join(project_dir, ".claude", VENDOR_OVERRIDE)):
            return 0
        deny(
            "Blocked by .claude/hooks/guard-protected-paths.py: "
            f"{target} is inside the fixed vendor/atsim review snapshot. AGENTS.md requires "
            "explicit review for updates, and scripts/verify-vendor.py checks it against "
            f"UPSTREAM-SHA256.json. If this update is authorized, create .claude/{VENDOR_OVERRIDE} "
            "for the duration of the task and remove it afterwards."
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
