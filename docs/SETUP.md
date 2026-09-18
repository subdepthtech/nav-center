# Repository and native tooling setup

Status recorded 2026-09-16 UTC. This is the living setup plan; update evidence and remaining gates as work proceeds. Configuration, executed validation, and release acceptance are separate states. [Operating runbook](TOOLING.md) · [Testing](TESTING.md) · [Architecture](ARCHITECTURE.md).

## Current outcome

Repository controls were changed and read back on GitHub. Documentation, pinned tool provisioning, upgraded CI, Sonar report preparation, ownership and templates are prepared locally. No source implementation, inherited tests, or vendor snapshot files were changed. Nothing has been committed, pushed, merged, released, submitted to Apple, or uploaded to Sonar by this setup task.

The worktree inherited substantial unpublished hardening. Its new CI relies on inherited test/release files absent from committed main. A working tooling PR cannot simply publish the whole tree without also publishing that implementation. The owner must decide whether to review/commit that baseline first or explicitly authorize a combined ready-for-review PR. Until then, setup remains a reviewable local delta.

## Phase 0 — baseline and toolchain

- [x] Confirm detached worktree at `0555cb0483f98de44e6c32a1a1cdd270d50a1abf`, matching original main HEAD.
- [x] Inventory 91 files: 38 tracked modifications and 25 untracked files. Original/worktree file bytes matched. Preserve original checkout; retain separate baseline and setup delta evidence.
- [x] Read repository instructions, package/source/test/release contracts, vendor manifest, tool versions and live GitHub settings.
- [x] Diagnose local tools: Command Line Tools Swift 6.4 is selected; Xcode 27.0 / 27A266a exists but its license is unaccepted. Do not accept it on the owner's behalf.
- [x] Select compatible CI: `macos-15`, explicit Xcode 26.3 / Swift 6.2.3; retain macOS 13 as deployment minimum, not verified support evidence.
- [x] Build the CLI with installed Command Line Tools using temporary build/cache directories; all four synthetic CLI tests passed.
- [ ] Owner completes Xcode license/first-launch setup. Full native app/XCTest, debug/release, sanitizers and actual coverage remain unverified in this task. The selected CI Xcode version is not installed locally.

## Phase 1 — repository management

- [x] Version shared `AGENTS.md`; ignore only personal `AGENTS.local.md` guidance.
- [x] Add architecture/testing/tooling docs and this checklist; mark the old product plan historical.
- [x] Add issue forms, PR template and CODEOWNERS using verified repository administrator `@austinkennethtucker`.
- [x] Replace vague security reporting instructions with the already-enabled GitHub private advisory route.
- [x] Inventory dependency/license boundaries; preserve the ATS snapshot's unresolved standalone MIT attribution notice.
- [ ] Publish the intended documentation/configuration revision after the inherited-baseline decision; local files are not yet effective repository policy on main.

## Phase 2 — CI and dependencies

- [x] Adapt existing CI/release workflows; retain release regressions, CLI behavior, coverage, ASAN and TSAN checks.
- [x] Put current-source/history Gitleaks and workflow checks before expensive native compilation. Use exact versions, full action SHAs and verified binary archive checksums.
- [x] Add official swift-format and focused nonduplicative SwiftLint as visible advisory baselines. Tests/builds/sanitizers remain blocking.
- [x] Validate genuine native report structure/paths/counts and retain reports/skips in explicit artifacts. No synthetic coverage is used as product evidence.
- [x] Add weekly Actions Dependabot; explicitly exclude bot rewrites of the frozen npm vendor snapshot. SwiftPM has no third-party dependencies yet.
- [x] Enable repository Dependabot alerts/security updates; keep existing CodeQL default setup for Swift/Actions, secret scanning and push protection.
- [ ] Execute the updated workflows on the exact intended hosted revision and record stable check names, provider, results and URLs.
- [ ] Obtain pinned-Xcode lint/coverage baselines and decide a scoped adoption change. The local formatter baseline contains 1,640 findings; no formatting rewrite was made.

## Phase 3 — SonarQube Cloud

- [x] Prepare a separate optional main-only reporting workflow, exact CI artifact binding, source/report allowlists, report hashes and path checks.
- [x] Create a `sonar` GitHub environment restricted to main. No token has been entered and `SONAR_ENABLED` remains unset.
- [x] Confirm the documented free OSS/EU path and Swift compatibility; do not select a paid trial or assume scoped OSS tokens.
- [ ] Owner signs in, personally accepts any terms, and supplies the actual existing/new OSS organization selection. The login tab is prepared for handoff.
- [ ] Install/authorize the SonarQubeCloud GitHub app for **nav-center only**, import the public project, disable automatic analysis and automatic project import, and read back settings.
- [ ] Store an expiring `SONAR_TOKEN` through secure UI/CLI in this repo's `sonar` environment. Record its real user-derived scope. Set verified organization/project variables.
- [ ] Analyze a vetted, successful native main revision; verify server-side file counts, coverage totals/paths, external findings and analyzer compatibility against native reports.
- [ ] Record explicit main baseline SHA/date, calibrated quality gate/new-code definition and representative changed-code results. Enable PR gating only after secure PR analysis and actual check behavior exist. Sonar remains nonrequired during calibration and does not replace tests or CodeQL.

## Phase 4 — enforcement and release evidence

- [x] Change workflow token defaults to read-only and disable workflow PR creation/approval.
- [x] Restrict Actions to GitHub-owned actions plus the approved Sonar scan action; require maintainer approval for all external-fork runs.
- [x] Create `release` environment: reviewer `austinkennethtucker`, main-only branch policy, self-review allowed for solo operation. Administrator bypass remains enabled by GitHub; no bot bypass or AI approval was configured.
- [x] Prepare a disabled main ruleset with PR/review-thread/check requirements, stale-review dismissal, no bypass actors, and no independent-review count that would lock out a solo maintainer.
- [x] Verify GitHub's SPDX endpoint and prepare source inventory retention with release evidence; document its limits and future final-artifact attestation.
- [ ] After successful candidate checks, activate the ruleset using the observed GitHub Actions names/provider and verify effective branch behavior. Main remains unprotected now.
- [ ] Enable full-SHA repository enforcement after the pinned workflows are published; current committed workflows still use floating major tags.
- [ ] Bind the published release workflow to the configured environment. Environment creation alone does not protect the existing legacy workflow.
- [ ] Confirm additional human owners if independent review is desired. Add signing credentials only through secure environment secrets, and obtain separate authorization before an actual release/signing/notarization run.
- [ ] Resolve vendor license notice, signed candidate, provenance, minimum-OS/architecture, GUI/accessibility, authenticated Codex and clean-device release gates. This setup does not establish release readiness.

## Phase 5 — optional independent review

- [x] Keep fresh-session Codex review as the default. Document a repository-only CodeRabbit OSS pilot and current eligibility/rate-limit caveats in the runbook.
- [ ] Only if elected after the core setup works: connect that single reviewer, measure unique findings/false positives/latency/cost, and retain human merge authority. No CodeRabbit installation or paid usage was initiated.

## Validation evidence

| Check | Observed result in this task |
| --- | --- |
| Preservation | Original baseline content unchanged; inherited application source, Swift tests, Python release/CLI tests and vendor files unchanged |
| Gitleaks 8.30.1 | No matches in isolated current intended source; no matches in all nine local Git commits |
| actionlint 1.7.12 | Passed all three prepared workflows |
| zizmor 1.30.1, offline auditor mode | Passed with one documented, narrowly scoped trusted-main `workflow_run` exception; no remaining findings |
| Shell syntax / diff whitespace | Passed |
| Release-script regressions | 15 passed, using synthetic signing/build/notary tools |
| ATS snapshot | All 11 hashes/inventory matched; 23 tests passed with an explicit synthetic root |
| Tooling tests | 8 passed: report counts/path/symlink/mismatch rejection plus synthetic native-test failure propagation through all three logged pipelines |
| CLI | Temporary Swift 6.4/CLT build passed; four black-box tests passed against the resolved executable |
| Formatting | 1,640 local strict findings; advisory, no source edits; pinned-Xcode baseline still pending |
| Native app, XCTest, ASAN/TSAN, coverage | Blocked/unverified: full Xcode license/setup pending; no test result fabricated |
| SwiftLint runtime | Official archive SHA-256/version and all five configured rule IDs verified. Lint invocation failed loading sourcekitdInProc (exit 133, invalid/empty report); licensed Xcode/SourceKit execution remains blocked |
| GitHub settings | Applied and read back; snapshot linked below |
| GitHub SPDX | Current asynchronous generation/fetch API returned SPDX-2.3 and three packages; retrieval/digest metadata retained. Repository-graph snapshot, not bound to candidate SHA or a complete binary inventory |
| Hosted candidate CI / Sonar ingestion / release | Not run; no published candidate or authenticated Sonar configuration |

The first CLI build attempt failed because the sandbox could not write the compiler cache; rerunning with task-local caches under authorized native execution passed. The first CLI test invocation used an assumed pre-6.4 output layout and did not execute the binary; after resolving the actual SwiftPM output path, all four tests passed. These setup failures were diagnosed, not treated as application defects.

## Evidence and next owner actions

- [GitHub settings readback](setup-evidence/github-settings-2026-09-16.json) and [preservation baseline](setup-evidence/preservation-baseline.json).
- [GitHub Actions settings](https://github.com/subdepthtech/nav-center/settings/actions), [environments](https://github.com/subdepthtech/nav-center/settings/environments), [rulesets](https://github.com/subdepthtech/nav-center/settings/rules), [private vulnerability reporting](https://github.com/subdepthtech/nav-center/security/advisories/new).
- Required input: complete Xcode's agreement/setup; sign in and choose the Sonar OSS organization (EU for a new free account); enter the token securely; decide whether inherited implementation is reviewed/committed first or may be included in a combined ready-for-review PR.

No pending question is permission to publish inherited implementation. The prepared ruleset, Sonar activation, hosted validation and release controls must be completed in the order described above.
