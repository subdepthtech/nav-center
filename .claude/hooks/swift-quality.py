#!/usr/bin/env python3
"""PostToolUse check on an edited Swift file.

CI runs SwiftLint and swift-format repository-wide as `continue-on-error`
adoption baselines, so drift is invisible until someone opens the uploaded
report. This runs them per edited file, but reports only what the edit ADDED:
each tool is also run against the file's content at HEAD, and findings are
surfaced only when the count went up. That keeps the repository's stated stance
-- never rewrite inherited source -- while still catching a regression the
moment it is introduced.

- SwiftLint enforces correctness rules only (.swiftlint.yml `only_rules`:
  force_cast, force_try, duplicate_conditions, ...). New findings exit 2.
- swift-format is the style baseline. New findings print on stdout, advisory.

Missing tools are skipped silently; they are checksum-pinned in CI via
scripts/bootstrap-tools.py and may not be installed locally.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

TIMEOUT_SECONDS = 45
MAX_REPORTED = 8


def run(argv, cwd):
    try:
        return subprocess.run(
            argv, cwd=cwd, capture_output=True, text=True, timeout=TIMEOUT_SECONDS
        )
    except (OSError, subprocess.SubprocessError):
        return None


def swiftlint_findings(path, project_dir, config):
    """Return [(identity, display)] so findings can be diffed across line shifts."""
    result = run(
        ["swiftlint", "lint", "--strict", "--no-cache", "--quiet",
         "--config", config, "--reporter", "json", path],
        project_dir,
    )
    if result is None:
        return None
    try:
        parsed = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        return None
    findings = []
    for item in parsed:
        identity = (item.get("rule_id", ""), item.get("reason", ""))
        display = "{}:{}: {} ({})".format(
            os.path.basename(item.get("file", path)),
            item.get("line", "?"),
            item.get("reason", ""),
            item.get("rule_id", ""),
        )
        findings.append((identity, display))
    return findings


def swift_format_findings(path, project_dir, config):
    """Return [(identity, display)]; identity drops line:column so inserting
    code above an inherited finding does not read as a new one."""
    result = run(
        ["xcrun", "swift-format", "lint", "--strict", "--configuration", config, path],
        project_dir,
    )
    if result is None:
        return None
    findings = []
    for line in (result.stdout + result.stderr).splitlines():
        line = line.strip()
        if ": error:" not in line and ": warning:" not in line:
            continue
        marker = ": error:" if ": error:" in line else ": warning:"
        location, _, message = line.partition(marker)
        identity = (marker.strip(": "), message.strip())
        display = "{}: {}".format(location.split("/")[-1], message.strip())
        findings.append((identity, display))
    return findings


def baseline_copy(relative, project_dir, tmpdir):
    """Write the HEAD content of `relative` to a temporary .swift file."""
    result = run(["git", "show", "HEAD:" + relative], project_dir)
    if result is None or result.returncode != 0:
        return None
    path = os.path.join(tmpdir, os.path.basename(relative))
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(result.stdout)
    return path


def regressions(collect, target, relative, project_dir, config, tmpdir):
    """Findings present now whose identity was not already present at HEAD."""
    current = collect(target, project_dir, config)
    if not current:
        return []
    baseline_path = baseline_copy(relative, project_dir, tmpdir)
    previous = collect(baseline_path, project_dir, config) if baseline_path else []
    if previous is None:
        return [display for _, display in current]

    added = Counter(identity for identity, _ in current)
    added.subtract(Counter(identity for identity, _ in previous))
    remaining = {identity: count for identity, count in added.items() if count > 0}
    if not remaining:
        return []

    reported = []
    for identity, display in current:
        if remaining.get(identity, 0) > 0:
            remaining[identity] -= 1
            reported.append(display)
    return reported


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        return 0

    raw = (payload.get("tool_input") or {}).get("file_path") or ""
    if not isinstance(raw, str) or not raw.endswith(".swift"):
        return 0

    project_dir = os.path.realpath(
        os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or os.getcwd()
    )
    target = os.path.realpath(raw if os.path.isabs(raw) else os.path.join(project_dir, raw))
    if not target.startswith(project_dir + os.sep) or not os.path.isfile(target):
        return 0

    relative = os.path.relpath(target, project_dir)
    if not (relative.startswith("Sources" + os.sep) or relative.startswith("Tests" + os.sep)):
        return 0

    status = 0
    with tempfile.TemporaryDirectory(prefix="nav-center-hook.") as tmpdir:
        lint_config = os.path.join(project_dir, ".swiftlint.yml")
        if shutil.which("swiftlint") and os.path.isfile(lint_config):
            added = regressions(
                swiftlint_findings, target, relative, project_dir, lint_config, tmpdir
            )
            if added:
                sys.stderr.write(
                    "SwiftLint correctness findings introduced in {} (CI lint baseline is advisory):\n{}\n".format(
                        relative, "\n".join(added[:MAX_REPORTED])
                    )
                )
                status = 2

        format_config = os.path.join(project_dir, ".swift-format")
        if shutil.which("xcrun") and os.path.isfile(format_config):
            added = regressions(
                swift_format_findings, target, relative, project_dir, format_config, tmpdir
            )
            if added:
                shown = "\n".join(added[:MAX_REPORTED])
                more = "" if len(added) <= MAX_REPORTED else "\n({} more)".format(
                    len(added) - MAX_REPORTED
                )
                print(
                    "swift-format baseline (advisory) — {} new finding(s) in {}:\n{}{}".format(
                        len(added), relative, shown, more
                    )
                )

    return status


if __name__ == "__main__":
    sys.exit(main())
