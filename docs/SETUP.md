# Repository and native tooling setup

Status recorded 2026-09-22 UTC. This is the living setup record. Configuration, executed validation, and release acceptance are separate states. [Operating runbook](TOOLING.md) · [Testing](TESTING.md) · [Architecture](ARCHITECTURE.md).

## Current outcome

The previously unpublished hardening and tooling baseline is on main through [PR #2](https://github.com/subdepthtech/nav-center/pull/2) and [PR #3](https://github.com/subdepthtech/nav-center/pull/3). The September 16 publication and local Xcode-license blockers are no longer current. The development closeout has explicit human authorization to review, fix, commit, push and merge its PRs; this does not authorize a binary release, distribution or Apple submission.

Main protection and full-SHA Actions enforcement are active and have been read back. Claude's repository allowlist startup failure was corrected, including its nested Bun action; a subsequent human-gated review run completed successfully. Sonar onboarding remains optional and deferred to the account owner.

[PR #4](https://github.com/subdepthtech/nav-center/pull/4) merged the exact-directory tracker correction. [PR #5](https://github.com/subdepthtech/nav-center/pull/5) updates the pinned Claude and Sonar actions. [PR #6](https://github.com/subdepthtech/nav-center/pull/6) supplies recoverable first-use tracker initialization and this closeout record. Evidence below identifies the tested source candidates; final integration is checked again on the merged main revision, with CI results retained on that revision. No application feature, integration or release gate is accepted merely because its setup is present.

## Repository controls

The [September 22 settings readback](setup-evidence/github-settings-2026-09-22.json) contains configuration metadata only. The [September 16 snapshot](setup-evidence/github-settings-2026-09-16.json) and [preservation baseline](setup-evidence/preservation-baseline.json) remain historical evidence.

| Control | Verified state |
| --- | --- |
| Main ruleset `23822967` | Active; PR required, review threads resolved, branch current with main, deletion and force-push prohibited; no bypass actors |
| Required checks | **Repository checks** and **Build, test and release contracts**, both bound to GitHub Actions app ID `15368` |
| Reviews | Stale approvals dismissed; zero required independent approvals avoids locking out the solo maintainer; human merge authorization remains required by project policy |
| Actions policy | GitHub-owned actions plus Sonar scan, Claude Code, and the exact nested Bun action; full commit SHAs required; other verified publishers are not implicitly allowed |
| Workflow token | Read-only defaults; workflow PR creation/approval disabled; all external-contributor fork runs require approval |
| Claude environment | Human reviewer `austinkennethtucker`; self-review allowed, administrator bypass disabled, PR branches allowed |
| Release environment | Same human reviewer; main only, self-review allowed; existing administrator bypass remains enabled and is not release authorization |
| Security | Secret scanning, push protection and Dependabot security updates enabled; existing CodeQL extended default setup covers Actions, Python and Swift |
| Sonar | Main-only environment exists; no repository variables or Sonar environment token configured; workflow remains off and nonrequired |

The published manual [Beta Release workflow](../.github/workflows/beta-release.yml) uses the `release` environment and restricts execution to main. Repository and release-environment secret-name inventories contain no Apple signing credentials. No credentials, organization-wide access or third-party service terms were added for this closeout.

## Validation evidence

| Scope | Observed evidence |
| --- | --- |
| Local and CI toolchains | Local `/Applications/Xcode.app`, Xcode 27.0 / `27A266a`, Swift 6.4; `xcodebuild -checkFirstLaunchStatus` passes. [Main CI run 35733117014](https://github.com/subdepthtech/nav-center/actions/runs/35733117014) records Xcode 26.3 / `17C529`, Apple Swift 6.2.4 and macOS 15.7.9 arm64. Its `6.2.3` version is swift-format, not the compiler. |
| PR #4 exact tracker binding | Merged at `579785023b8299acaaf36b84fe1ff890cf17d403` after independent review and successful [fresh CI](https://github.com/subdepthtech/nav-center/actions/runs/35729198025) on head `01bebab4eb40a33bcb07f56c7212852211d95683`, including both sanitizers. |
| PR #5 Actions updates | Merged at `ae988d7e0c10171004b457e2e584e177dae8b5cd` after refreshing onto PR #4 main at head `7257fc9866505472c319c6bba701dde38eaf576b`; [CI](https://github.com/subdepthtech/nav-center/actions/runs/35729936348) and [CodeQL](https://github.com/subdepthtech/nav-center/actions/runs/35729934702) passed. The [Claude run](https://github.com/subdepthtech/nav-center/actions/runs/35729936263) was admitted but deliberately skipped model execution because its workflow differed from main; this preserves the action's workflow-validation boundary. The recomputed diff still contains only the reviewed action updates; official upstream pins, actionlint 1.7.12 and whitespace checks passed. |
| Claude startup recovery | [Review run 35729198022](https://github.com/subdepthtech/nav-center/actions/runs/35729198022) succeeded on PR #4 head `01bebab4eb40a33bcb07f56c7212852211d95683` after the environment approval. This verifies execution beyond the former zero-job startup failure. A fresh [conversation event](https://github.com/subdepthtech/nav-center/actions/runs/35729865630) was admitted and correctly skipped without a trigger mention; it was not an authenticated conversation test. |
| First-use tracker initialization (F2) | Fix `9f94675dec316bf1889e6d57492f79bc9d07afd8`: the new invalid-UTF8 first-action/retry regression failed against unchanged pre-fix source. Separate schema initialization keeps a valid empty tracker after a rejected action; existing invalid databases remain rejected unchanged. Independent review passed; all 48 core tests and normal unfiltered coverage discovery passed (178 tests, 3 optional skips, zero failures). [Hosted native CI](https://github.com/subdepthtech/nav-center/actions/runs/35729584599) and [CodeQL](https://github.com/subdepthtech/nav-center/actions/runs/35729581087) also passed on that source. |
| Synthetic CLI and app smoke | On application source `9f94675`: explicit disposable workspace, initialization/doctor, import, package preview/create, duplicate refusal without mutation and redacted diagnostics passed. The actual app displayed that workspace, changed the synthetic package to Submitted then Interview, retained Interview after Refresh and rendered posting/resume previews. Read-only SQLite verification found one exact-directory row and exactly two expected history events; derived Markdown matched. The task-owned app exited normally. This is a focused smoke, not full GUI/accessibility acceptance. |
| Real export smoke | On the same source, installed Pandoc 3.11, Chrome and Poppler 26.09.0 produced HTML, DOCX, PDF and both text extracts from only the synthetic resume. Expected content was verified in the outputs. Broader conversion/Unicode/layout acceptance remains separate. |
| Script and vendor contracts | Python discovery: 55 tests, 4 CLI skips without `NAVCENTERCTL`; separate CLI smoke passed. All 11 vendor manifest files and 23 synthetic vendor tests passed; shell syntax passed. Stubbed signing/notary tests do not establish Apple acceptance. |

Hosted native CI covers debug/release builds, XCTest coverage, address/thread sanitizers, CLI behavior and synthetic release-script contracts. Its artifacts retain actual skip reasons. Formatting and focused SwiftLint are advisory during adoption; review the pinned-Xcode reports before promoting either to a required gate. Historical local formatter counts and the old SourceKit startup failure are not current release evidence.

## Deferred Sonar onboarding

Sonar is not a development-closeout blocker. The account owner must choose the suitable organization, personally accept any service terms, authorize the GitHub app for **nav-center only**, disable automatic analysis, and supply an expiring analysis credential through the secure environment UI/CLI. No paid trial or purchase is authorized.

Existing [CodeQL alert #3](https://github.com/subdepthtech/nav-center/security/code-scanning/3) remains open. Independent static reviews found no actionable fork/PR checkout path: the job guard admits only successful same-repository main push or manual CI runs before checking out their exact SHA and downloading their exact run's artifact. Sonar inactivity is not the basis for that conclusion. No alert suppression or workflow relaxation was made; reassess the trust boundary before enabling PR analysis.

After those owner steps, follow [TOOLING.md](TOOLING.md#sonarqube-cloud-onboarding) to set verified project variables and enable the workflow. Validate actual server-side source counts, coverage, findings and quality-gate results against the exact successful native CI artifact. Keep Sonar nonrequired until its imports, baseline and secure PR-check behavior have been demonstrated. A prepared workflow or scanner exit code does not establish ingestion.

## Next milestone: reliable, installable macOS beta

Development checks do not complete these acceptance gates:

- Exercise the native GUI with a disposable workspace: first-use setup, create/edit/save, tracker updates, cleanup/recovery and meaningful error states. Verify keyboard and VoiceOver accessibility. Model tests and a short launch smoke are insufficient.
- Extend the successful synthetic export smoke to representative Unicode, layout and error cases. Verify a reviewed installed ATS executable and a live signed-in Codex session with package-edit confirmation separately. Standard native tests still skip the opt-in installed Chrome and two ATS tests unless explicitly configured; the separate export smoke does not replace those tests. Preserve skipped or unavailable evidence.
- Complete the frozen ATS snapshot's missing standalone license/attribution notice before distribution. Keep its manifest and dependency boundary intact; it is not bundled or activated by default.
- Select and test the supported macOS and architecture matrix. The declared macOS 13 minimum is not established by local macOS 27 or hosted macOS 15 results.
- Under separate release authorization, configure Apple signing credentials securely and validate a candidate's nested app/CLI and outer DMG signatures, notarization/stapling, Gatekeeper behavior, source/toolchain/checksum lineage and final-artifact provenance.
- Verify a downloaded candidate on a clean device, including install, first launch, update, uninstall and data preservation. Retain results in the [public release checklist](PUBLIC_RELEASE_CHECKLIST.md); do not infer acceptance from successful build or upload.

CodeRabbit and additional analysis services remain optional. No new product/iOS work or binary distribution is part of this closeout.
