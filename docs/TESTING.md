# Testing

Use synthetic fixtures and disposable workspaces. Do not point checks at real resumes, application history, tracker databases, vaults or account credentials. Keep native build products and local evidence in temporary directories. Record the source revision, toolchain, command, exit status and skipped tests with each validation run.

## Native toolchain

CI selects `/Applications/Xcode_26.3.app` on the standard `macos-15` arm64 runner. The `native-quality/toolchain.txt` artifact from [main CI run 35733117014](https://github.com/subdepthtech/nav-center/actions/runs/35733117014) records macOS 15.7.9, Xcode 26.3 build `17C529`, and Apple Swift 6.2.4 (`swiftlang-6.2.4.1.4`). Its later `6.2.3` line is the swift-format version, not the compiler. Swift 6.2.4 is within [SonarCloud's documented Swift support through 6.3](https://docs.sonarsource.com/sonarqube-cloud/analyzing-source-code/languages/swift). The package deployment minimum remains macOS 13; a test on macOS 15 does not validate that minimum.

Use an installed, user-licensed full Xcode. Command Line Tools alone are not a substitute for the SwiftUI macro, XCTest, SourceKit and SDK combination this project needs. Accept an installed Xcode license on the user's behalf only with explicit authorization in the current task, as described in `AGENTS.md`; that authorization also applies to delegated agents working on the task. Preserve OS privilege requirements and verify acceptance before retrying native checks. If the named version is installed elsewhere, use its actual path and record the difference.

Run the examples from the repository root in one Bash session:

```bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer
nav_check_root=$(mktemp -d "${TMPDIR:-/tmp}/nav-center-check.XXXXXX")
nav_build_root="$nav_check_root/build"
nav_report_root="$nav_check_root/reports/native"
mkdir -p "$nav_report_root"
export NAV_CENTER_WORKSPACE_ROOT="$nav_check_root/workspace"
export NAV_CENTER_DIST_DIR="$nav_check_root/dist"
export NAV_CENTER_SKIP_VAULT_SYNC=1

xcodebuild -version
xcrun swift --version
xcrun llvm-cov --version
git rev-parse HEAD
git status --short
```

A source revision alone does not identify uncommitted changes: retain the working-tree diff or the setup inventory alongside results. If Xcode license/first-launch setup or SourceKit fails, report a toolchain blocker and fix that prerequisite before retrying the same command. Do not classify it as a source failure or weaken tests to pass.

## Standard checks

```bash
# CI checks the committed range; git diff --check only sees uncommitted work.
git log --format= --check --diff-merges=remerge "$(git merge-base main HEAD)..HEAD"
git diff --check
for nav_script in scripts/*.sh; do bash -n "$nav_script"; done
python3 -B -m unittest discover -s scripts/tests -v

xcrun swift build --scratch-path "$nav_build_root" --enable-code-coverage
xcrun swift test --scratch-path "$nav_build_root" --enable-code-coverage \
  2>&1 | tee "$nav_report_root/swift-tests.log"
xcrun swift build --scratch-path "$nav_check_root/release" -c release

NAVCENTERCTL="$(xcrun swift build --scratch-path "$nav_build_root" --show-bin-path)/navcenterctl" \
  python3 -B scripts/tests/test_cli.py -v
NAVCENTERCTL="$(xcrun swift build --scratch-path "$nav_check_root/release" -c release --show-bin-path)/navcenterctl" \
  python3 -B scripts/tests/test_cli.py -v
```

[`NavCenterTests`](../Tests/NavCenterTests) covers workspace/data safety, SQLite updates and recovery, imports and export contracts, dashboard state, Codex protocol/staging, and synthetic process/network cases. Some tests create an ephemeral loopback HTTP listener; a sandbox that blocks it limits validation rather than proving a source defect. Building all products in the same scratch directory also supplies the sibling `navcenterctl` used by the native cleanup-restoration test.

[`ToolProbeReadinessTests`](../Tests/NavCenterTests/ToolProbeReadinessTests.swift) checks override, PATH, and fallback resolution without executing a tool. Tests that assert `.missing` must inject `fallbackDirectories: []`; a tool installed in `/opt/homebrew/bin`, `/usr/local/bin`, or `~/.local/bin` on the machine running the tests would otherwise satisfy the lookup.

[`scripts/tests/test_cli.py`](../scripts/tests/test_cli.py) skips without `NAVCENTERCTL`, so test discovery alone is not CLI validation. Run it explicitly against the built executable as above. [`test_release_scripts.py`](../scripts/tests/test_release_scripts.py) uses synthetic tools for compilation, signing, notarization and Gatekeeper behavior. These regressions validate script contracts, not Apple service acceptance or a usable signed artifact.

Run the native sanitizer checks in separate build directories:

```bash
xcrun swift build --scratch-path "$nav_check_root/asan" --sanitize=address
xcrun swift test --scratch-path "$nav_check_root/asan" --sanitize=address \
  2>&1 | tee "$nav_report_root/asan.log"
xcrun swift build --scratch-path "$nav_check_root/tsan" --sanitize=thread
xcrun swift test --scratch-path "$nav_check_root/tsan" --sanitize=thread \
  2>&1 | tee "$nav_report_root/tsan.log"
```

Retain a failed sanitizer result as a failure or a diagnosed platform/tool limitation; do not silently replace it with an unsanitized pass. Run checks in proportion to the change, while completing the required native/release contracts for integration candidates.

## Explicit integration tests

The standard Swift test run can skip real Chrome, the installed export chain, and installed ATS checks. `scripts/tests/test_cli.py` skips its real export lane the same way. Preserve the skip reasons in the test log and CI summary.

For an already installed Chrome at `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`:

```bash
NAV_CENTER_TEST_REAL_CHROME=1 \
NAV_CENTER_RENDERER_EVIDENCE_DIR="$nav_check_root/renderer-evidence" \
  xcrun swift test --scratch-path "$nav_build_root" \
  --filter RendererReadinessTests.testInstalledChromeRendersStyledUnicodeDocumentWithPrivateProfile
```

This test uses a synthetic document and a fresh Chrome profile, verifies PDF text, and can retain HTML/PDF/text/PNG evidence. With `NAV_CENTER_TEST_REAL_CHROME=1`, a missing Chrome fails the test. It skips when that variable is unset and does not install Chrome. It does not exercise the complete Pandoc-to-DOCX/PDF-to-Poppler export chain. See [`RendererReadinessTests`](../Tests/NavCenterTests/RendererReadinessTests.swift).

For the complete built-in export chain (Pandoc, Google Chrome, and pdftotext) set `NAV_CENTER_TEST_REAL_EXPORT=1`. Both checks skip only when that variable is not `1`. When it is `1`, a missing tool or a failed export fails the test; neither check installs tools or reads the Application Support workspace.

```bash
NAV_CENTER_TEST_REAL_EXPORT=1 \
  xcrun swift test --scratch-path "$nav_build_root" \
  --filter ExportToolReadinessTests.testInstalledExportChainProducesCompleteArtifactSet

NAV_CENTER_TEST_REAL_EXPORT=1 \
NAVCENTERCTL="$(xcrun swift build --show-bin-path --scratch-path "$nav_build_root")/navcenterctl" \
  python3 -B scripts/tests/test_cli.py -v
```

The Swift test resolves Pandoc, pdftotext, and Chrome with the default probe, exports one synthetic resume, and requires `Resume_*.html`, `.docx`, `.pdf`, `.docx.txt`, and `.pdf.txt`, with a PDF header and non-empty text extractions. The `test_cli.py` real lane runs `export-artifacts` with no tool overrides and the same five-file check, with a 120 second timeout. See [`ExportToolReadinessTests`](../Tests/NavCenterTests/ExportToolReadinessTests.swift).
Both real-export lanes remove `NAV_CENTER_VAULT_DIR` and set `NAV_CENTER_SKIP_VAULT_SYNC=1`, so a configured vault is never written.

For a separately reviewed, installed ATS executable, substitute its absolute path:

```bash
NAV_CENTER_TEST_ATSIM_BIN=/absolute/path/to/atsim \
  xcrun swift test --scratch-path "$nav_build_root" \
  --filter ATSActionReadinessTests.testInstalledATS
```

The two installed-ATS tests exercise a synthetic scan/report and input-alias rejection. `NAV_CENTER_TEST_ATSIM_BIN` is the test opt-in; production executable selection uses `NAV_CENTER_ATSIM_BIN`. The action supplies `ATSIM_JOB_HUNT_ROOT` for its private staging workspace. The vendored snapshot alone does not enable this integration; see [its provenance and license caveat](../vendor/atsim/UPSTREAM.md). Stubbed ATS/converter cases prove validation and rollback contracts, not compatibility with a real external tool.

## Integration acceptance lane

Run `scripts/integration-acceptance.sh /absolute/path/to/output` from the repository root with a licensed Xcode toolchain, Python 3, installed atsim, Pandoc, Poppler `pdftotext`, and Google Chrome. Set `NAV_CENTER_ATSIM_BIN` to an absolute executable path when atsim is not on PATH. The script builds `navcenterctl`, reads its redacted `doctor --json` report, records observed tool versions, and writes lane logs plus `integration-acceptance.json` and `.md` to the chosen directory. Use a temporary output directory and synthetic test data.

The requested atsim, Pandoc, pdftotext, and Chrome tools are mandatory for this lane. A missing or invalid tool fails before tests run. Any explicit XCTest or unittest skip, missing execution summary, test failure, or nonzero exit fails the lane; the summary records the outcome. Ruby and Codex versions are recorded when present, but this script does not run live Codex acceptance. CI runs this lane only on manual `workflow_dispatch`, not on push or pull request.

### Codex live acceptance (manual)

Use a disposable synthetic package and a signed-in maintainer session. Record the observed result in the beta setup evidence; this checklist is separate from the automated lane.

| Check | Pass/Fail |
| --- | --- |
| Record `codex --version` in the evidence. | |
| A signed-in `codex app-server` starts from the Codex panel. | |
| One chat without edits completes. | |
| One chat proposing edits requires confirmation, then applies only to package Markdown. | |
| The staging directory has mode 0700. | |
| The server is stopped before changes are applied. | |
| Compare `ls -la ~/.codex` before and after; Nav Center does not modify it. | |
| No private data is used. | |

## Coverage and CI evidence

The stable native CI check is **Build, test and release contracts**; the separate tooling check is **Repository checks**. Their definitions are in [CI](../.github/workflows/ci.yml). Configuration present in the source does not mean hosted checks have run successfully for that revision.

Native reports are assembled under `reports/native` in CI. [`scripts/export-coverage.sh`](../scripts/export-coverage.sh) exports genuine SwiftPM coverage; [`scripts/check-analysis-reports.py`](../scripts/check-analysis-reports.py) validates and relativizes the analysis inputs before Sonar upload. After the coverage test succeeds, and with the repository's pinned SwiftLint available on PATH, generate local evidence with:

```bash
bash scripts/export-coverage.sh "$nav_build_root" "$nav_report_root"
swiftlint lint --strict --no-cache --config .swiftlint.yml --reporter json \
  > "$nav_report_root/swiftlint.json"
python3 -B scripts/check-analysis-reports.py "$nav_report_root"
```

Keep the source revision paired with the reports. These local commands do not upload to Sonar. The separate [Sonar reporting workflow](../.github/workflows/sonar.yml) consumes the exact successful main-branch CI run's artifact; PRs, forks and Dependabot do not receive analysis credentials or Sonar analysis in this initial configuration.

The exporter uses SwiftPM's reported binary directory and accepts the Xcode 26 package test bundle (`NavCenterPackageTests.xctest`) or Xcode 27 test-target bundle (`NavCenterTests.xctest`). It requires a nonempty binary and coverage profile, rejects an ambiguous scratch directory containing both bundles, and preserves LLVM failures and report validation. Use a fresh scratch directory when switching toolchains.

SwiftPM's `--enable-code-coverage` produces LLVM profile data and exported JSON; `xcrun swift test --scratch-path "$nav_build_root" --show-codecov-path` identifies that JSON. It does not create an Xcode `.xcresult` bundle for xccov. The Sonar import uses `llvm-cov show` text through `sonar.swift.coverage.reportPaths`, and SwiftLint JSON through `sonar.swift.swiftLint.reportPaths`. Native tests still run separately. [SwiftPM implementation](https://raw.githubusercontent.com/swiftlang/swift-package-manager/swift-6.2.3-RELEASE/Sources/Commands/SwiftTestCommand.swift), [Sonar coverage formats](https://docs.sonarsource.com/sonarqube-cloud/analyzing-source-code/test-coverage/test-coverage-parameters), [SwiftLint import](https://docs.sonarsource.com/sonarqube-cloud/analyzing-source-code/importing-external-issues/external-analyzer-reports#swift).

Before accepting an import, confirm the report revision, nonzero maintained source-file count, resolved paths, and valid line/count data. A valid SwiftLint report may contain zero findings. Surface source files absent from coverage; do not interpret missing reports or skipped integrations as zero defects or tested code. Exclude generated outputs and the vendored ATS snapshot from maintained-code metrics while preserving their separate inventory/integrity checks. Compare imported coverage/file counts with native evidence during Sonar calibration; local report validation alone does not prove server-side ingestion.

## Manual and release gaps

The current UX tests exercise models and state transitions. They do not drive the native UI, establish VoiceOver/keyboard accessibility, validate a live signed-in Codex session, or prove real-device behavior. The brief launch smoke check in [Release](RELEASE.md) proves only short-lived process survival. Real conversion, UI/accessibility, minimum-macOS, architecture, signed/notarized download and clean-device install/update/uninstall evidence remain separate checks in the [public release checklist](PUBLIC_RELEASE_CHECKLIST.md). Preserve useful temporary evidence until review is complete, then remove only the disposable directory created for the run.

## GUI and accessibility gate (manual)

Run this checklist once on the beta candidate on a Mac with VoiceOver and a disposable workspace. Record Pass or Fail, observations, candidate version, macOS version, and tester in `docs/setup-evidence/beta-<version>/accessibility-checklist.md`. This checklist is a manual gate; a successful Swift test run does not fill in its results.

| Check | Expected result | Pass/Fail |
| --- | --- | --- |
| VoiceOver sidebar and toolbar tab order | Each of the seven sections, search field, and refresh control is reachable and named. |  |
| VoiceOver package rail tab order | Rail actions, confirmation primary/cancel controls, and status buttons are reachable and named. |  |
| VoiceOver status history | Status changes are read in order with old and new status and timestamp. |  |
| VoiceOver cleanup sheet | Preview, Remove, sheet Cancel, and sheet Remove are reachable; the removal consequence is announced. |  |
| VoiceOver Codex panel | Launcher, account controls, input, edit toggles, Send, Stop when present, and Close are reachable and named. |  |
| Rail, status, cleanup, and Codex announcements | Rail confirmation, status update, cleanup sheet, and Codex control purpose/state are understandable when spoken. |  |
| ⌘1 Overview | Opens Overview and closes package detail. |  |
| ⌘2 Applications | Opens Applications and closes package detail. |  |
| ⌘3 Packages | Opens Packages and closes package detail. |  |
| ⌘4 Job Searches | Opens Job Searches and closes package detail. |  |
| ⌘5 Master Resume | Opens Master Resume and closes package detail. |  |
| ⌘6 Exports | Opens Exports and closes package detail. |  |
| ⌘7 Settings | Opens Settings and closes package detail. |  |
| ⌘, Settings | Opens the Settings destination in the same window. |  |
| ⌘[ Back to List | Closes package detail; unavailable without an open package. |  |
| ⌘F Find | Focuses the toolbar application search. |  |
| ⌘⇧C Toggle Codex Panel | Opens or closes the panel; input is focused on open. |  |
| ⌘⇧A Run ATS Scan… | Opens the package rail confirmation and focuses its primary button; does not run the scan. |  |
| ⌘⇧E Export Artifacts… | Opens the package rail confirmation and focuses its primary button; does not export. |  |
| ⌘R Refresh Dashboard | Refreshes local dashboard data. |  |
| Help → Copy Redacted Diagnostics | Copies redacted JSON and shows a transient confirmation; no private workspace path or document contents appear. |  |
| 820×620 minimum window | Review pane and Codex panel remain visible without clipping; scrollable content stays reachable. |  |
| Reduce Motion | Codex open and close remain usable with reduced animation. |  |
| Full Keyboard Access | Every actionable control, including menus, sheets, and icon buttons, can be reached and operated. |  |
