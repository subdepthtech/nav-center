---
name: ci-gate
description: Run this repository's CI gate locally and report pass/fail/blocked per gate with evidence paths. Use before claiming integration or release readiness, before opening a PR, or whenever asked to "run the full checks" on Nav Center.
disable-model-invocation: true
---

# Local CI gate

This helper runs the native and script checks listed below in disposable directories.
It does not run every hosted CI gate: Gitleaks source/history scans, actionlint,
zizmor, and the vendored ATS unit suite must be checked separately. Neither mode
alone establishes a complete CI pass.

## Usage

```sh
bash .claude/skills/ci-gate/run-gate.sh          # standard
bash .claude/skills/ci-gate/run-gate.sh --full   # adds sanitizers and report export
```

Standard mode runs: committed-range whitespace/conflict-marker check, `bash -n`
over `scripts/*.sh`, the Python release and tooling suites, `verify-vendor.py`,
`swift build`/`swift test` with coverage, `swift build -c release`, and
`test_cli.py` against the debug `navcenterctl`.

`--full` adds the release-configuration CLI run, address and thread sanitizers in
their own scratch paths, `export-coverage.sh`, a SwiftLint JSON report, and
`check-analysis-reports.py`. Use it for an integration candidate or before any
release-readiness claim; sanitizer builds are slow, so standard mode is the right
default during iteration.

## What the script guarantees

- Every gate runs even after an earlier one fails, so one invocation reports the
  whole picture instead of stopping at the first error.
- All build products, workspaces and logs live in one `mktemp -d` run directory.
  `NAV_CENTER_WORKSPACE_ROOT` points inside it and `NAV_CENTER_SKIP_VAULT_SYNC=1`
  is set, so the gate never touches the real Application Support workspace.
- `DEVELOPER_DIR` is set to the pinned Xcode 26.6 when present; the actual
  toolchain, revision and working-tree dirt are recorded in
  `<run>/reports/native/toolchain.txt`.

## Reading the result

`BLOCKED` is distinct from `FAIL` on purpose. A gate whose log mentions an Xcode
license, first-launch setup or SourceKit problem is a toolchain prerequisite, not
a source defect — per `AGENTS.md`, fix the prerequisite and rerun that gate rather
than reporting a source failure or weakening a test. Accepting an Xcode license on
the user's behalf requires explicit authorization in the current task.

When reporting results, name the revision, the mode used, and the gates that did
not run. The script prints all three. Never present standard mode as the full gate,
and never present any local run as distribution readiness: signed and notarized
artifacts, UI and VoiceOver behavior, minimum-macOS support, real Chrome and
installed-ATS integrations are separate evidence, as `docs/TESTING.md` and
`docs/PUBLIC_RELEASE_CHECKLIST.md` describe.

The run directory is disposable. Keep it until the change is reviewed, then remove
only that directory.
