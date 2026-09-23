# Tooling operations

Use [SETUP.md](SETUP.md) for current completion and blockers, [TESTING.md](TESTING.md) for native commands, and [ARCHITECTURE.md](ARCHITECTURE.md) for source boundaries. All examples run from the repository root. Tooling checks use synthetic fixtures; only vetted source and reports belong in hosted analysis.

## Checks and tool versions

| Layer | Tool / check | Role |
| --- | --- | --- |
| Repository | Gitleaks 8.30.1 | Current source and full Git history, with redacted findings |
| Workflows | actionlint 1.7.12; zizmor 1.30.1 auditor mode | YAML/expression/shell checks and workflow security |
| Native | CI: Xcode 26.6 on macos-26 (Swift version recorded in the CI toolchain artifact); local toolchain recorded in SETUP.md | Full builds, XCTest, real coverage, CLI and sanitizers |
| Formatting | Apple's official swift-format from the selected Xcode | Read-only style baseline; advisory during adoption |
| Swift lint | SwiftLint 0.65.1 | Five correctness rules; no duplicate whitespace rules; advisory baseline |
| Security | Existing CodeQL default setup, secret scanning, push protection | Preserve Swift/Actions extended analysis and repository secret controls |
| Quality | SonarQube Cloud | Optional maintained-code reporting after successful main CI; native tests still required |
| Dependencies | Dependabot; GitHub SPDX export | Actions updates and source dependency inventory; reviewed vendor exception |

[`scripts/tool-versions.json`](../scripts/tool-versions.json) records exact official release URLs and archive SHA-256 values for macOS arm64/x86_64 and Linux x86_64 where used. Swift-format is tied to Xcode, not a separate unofficial formatter. The installer reads only each requested executable from its verified archive and does not install global packages:

```bash
python3 scripts/bootstrap-tools.py --tool gitleaks --tool actionlint --tool zizmor --tool swiftlint
export PATH="$PWD/.tools/bin:$PATH"
actionlint
zizmor --offline --persona auditor .github/workflows
python3 -B scripts/verify-vendor.py
python3 -B -m unittest discover -s scripts/tests -p 'test_tooling.py' -v
```

On Linux omit SwiftLint; native checks run on macOS. Existing matching installed tools can be used locally. CI always downloads the pinned archives into `$RUNNER_TEMP`, fails on checksum errors, and does not use floating Homebrew installs. Update version, URL and hash together after checking the upstream official release. Dependabot updates Actions SHAs, not this binary inventory or Xcode selection. Review these pins regularly and after runner/toolchain changes.

Run secret scans before builds so generated files cannot hide source findings. In a disposable clean checkout:

```bash
gitleaks dir . --redact
gitleaks git . --log-opts="--all" --redact
```

For an existing dirty checkout, scan an isolated copy of tracked and intended untracked source. Do not sweep ignored private workspaces or upload secret reports. Review data sensitivity separately: absence of recognized secrets does not prove every file is publishable.

The one zizmor exception is documented inline on Sonar's `workflow_run` trigger. It is constrained to successful, same-repository main push/manual CI runs; checks out that exact SHA; verifies exact-run artifact hashes, revision, paths and counts; and executes no artifact or checked-out script. PRs/forks/Dependabot cannot enter that credential-bearing job. Keep these conditions together when editing the workflow. Auditor mode currently has no other suppressed findings.

## Native reports and lint adoption

CI uploads `native-quality` for 14 days, even on a failed native job when reports exist. Logs preserve real XCTest skips; integration-scope text explicitly identifies unrun Chrome/ATS/Codex/UI/signing work. Sanitizer/test/build failures fail CI. Formatting and SwiftLint failures are visibly reported as advisory outcomes during baseline calibration; a missing/invalid SwiftLint report still fails analysis-report validation.

The initial September 16 formatter baseline came from Command Line Tools Swift 6.4, whose formatter reports version `main`. It is historical, not the pinned CI baseline. Use the exact successful Xcode 26.6 CI artifact before enforcing style. An inherited `try!` in `Utilities.swift` is also visible to the new focused rules. Resolve or explicitly review findings in a separate scoped source change; never silently reformat inherited implementation. Promote selected lint checks to required status only after a compatible hosted baseline and a clean intended revision.

Coverage generation exports native `llvm-cov show` text and LLVM JSON. The validator rejects empty, duplicate, impossible-count, unmaintained, or external-path reports; converts verified source paths to repository-relative paths; and records source files absent from coverage. It does not invent missing coverage. Sonar consumes the text/SwiftLint JSON, not generic XML or an unrelated `.xcresult` converter.

## SonarQube Cloud onboarding

The workflow is published but remains off until `SONAR_ENABLED=true` is deliberately set. Onboarding is deferred to the account owner and does not block development closeout; no Sonar token or project variables are configured in the September 22 readback. Use an existing suitable organization. For a new organization, choose the explicit OSS plan: public projects are free, with public branch/PR analysis; private projects are excluded. New free accounts use EU; US currently requires Enterprise. Do not start a paid trial or purchase a plan. [Plans](https://docs.sonarsource.com/sonarqube-cloud/administering-sonarcloud/managing-subscription/subscription-plans), [region constraints](https://docs.sonarsource.com/sonarqube-cloud/getting-started/choosing-your-region).

1. The account owner signs in and accepts any service terms personally. Import the actual GitHub organization and select only `subdepthtech/nav-center` for the SonarQubeCloud GitHub app. Do not grant all-repository access or enable automatic project import.
2. Select the actual project, record its organization key and project key, and disable **Administration → Analysis Method → Automatic Analysis**. CI and automatic analysis must not compete; automatic analysis cannot import these reports. [Analysis modes](https://docs.sonarsource.com/sonarqube-cloud/analyzing-source-code/automatic-analysis).
3. Create an expiring token through Sonar's secure UI and store it in the repository's **sonar environment** as `SONAR_TOKEN`. Never send it in chat or put it in a file. OSS personal tokens inherit the user's permissions; do not describe them as project-scoped. Organization-scoped tokens are documented for Team/Enterprise. Prefer an existing least-privileged analysis identity where available. [Token scope](https://docs.sonarsource.com/sonarqube-cloud/administering-sonarcloud/managing-organization/scoped-organization-tokens).
4. Set repository Actions variables `SONAR_ORGANIZATION` and `SONAR_PROJECT_KEY` to the verified keys. Set `SONAR_ENABLED=true` only after automatic analysis is off, the vetted revision is published, and native CI reports pass. The workflow uses the default EU endpoint; a different existing region needs an explicit reviewed configuration change.

For secure CLI token entry, the owner can run this interactive command (no token argument or chat message):

```bash
gh secret set SONAR_TOKEN --repo subdepthtech/nav-center --env sonar
```

The separate Sonar workflow needs only `contents: read` and `actions: read`; the token is exposed only to the official, SHA-pinned scan step. Its `sonar` environment accepts only main. It analyzes `Sources/**/*.swift` and `Tests/**/*.swift`. Vendor files, workspace content, generated artifacts and ignored directories are outside maintained-code metrics. Secret scans and vendor integrity review retain their own broader source scope.

## Sonar calibration and eventual gate

Record the first analyzed main SHA/date and Sonar analysis link in SETUP.md. Confirm source/test counts, the coverage text import, covered/executable lines, absent CLI coverage, and SwiftLint finding counts against `analysis-summary.json`. Scanner exit success is not proof that the server imported a report or accepted a quality gate. Review unexpected exclusions and security hotspots explicitly. The observed CI compiler, Swift 6.2.4, is within documented Sonar Cloud support through 6.3; local Swift 6.4 analysis is not established by that support statement. [Swift support](https://docs.sonarsource.com/sonarqube-cloud/analyzing-source-code/languages/swift).

Begin with the standard quality gate visible but nonrequired. After the native imports and useful findings are confirmed, define new code relative to the recorded baseline/reference branch, inspect a representative changed-code analysis, and verify that a deliberate gate failure is visible. Record the selected gate and thresholds. Only then require the actual Sonar check name observed on a tested PR; the initial main-only workflow must first be extended for secure PR analysis. Never require a check that this workflow cannot emit for PRs. Existing debt remains an explicit backlog rather than a fabricated clean baseline. [Quality-gate operation](https://docs.sonarsource.com/sonarqube-cloud/standards/managing-quality-gates/introduction-to-quality-gates).

## GitHub controls and maintenance

Current repository settings are captured in the [September 22 readback](setup-evidence/github-settings-2026-09-22.json); the September 16 snapshot is historical. The closeout used existing repository-admin access without adding organization-wide access or credentials. Settings payloads under [`.github/settings`](../.github/settings) describe the applied controls; changing a local JSON file does not apply it to GitHub.

Workflow token defaults are read-only, workflow PR creation/approval is off, and all external-contributor fork runs need maintainer approval. The repository allows GitHub-owned actions, `SonarSource/sonarqube-scan-action`, `anthropics/claude-code-action`, and only the reviewed `oven-sh/setup-bun` commit `0c5077e51419868618aeaa5fe8019c62421857d6`. Full-SHA enforcement is active, including for the allowlisted actions. Other verified publishers are not implicitly permitted. When updating a composite action, inspect its nested action references as well as the outer SHA; an omitted nested action can still prevent startup.

The `claude` environment requires human reviewer `austinkennethtucker`, permits self-review for solo operation and has administrator bypass disabled. It allows PR branches so both review and conversation workflows can reach their approval gate. The allowlist correction was verified by [successful review run 35729198022](https://github.com/subdepthtech/nav-center/actions/runs/35729198022). Preserve this approval boundary; a gate approval does not authorize an autonomous merge or release. Claude is optional and is not a required main check.

The active main ruleset requires PRs, resolved review threads, and successful **Repository checks** and **Build, test and release contracts** against a branch current with main. Both check contexts are bound to GitHub Actions app ID `15368`. Deletion and force-push are prohibited; there are no bypass actors. Stale approvals are dismissed, with zero independent approvals required until a second reviewer is confirmed. `CODEOWNERS` routes review to `@austinkennethtucker`; human merge authorization remains a project requirement.

Maintain these controls when changing workflows:

1. Verify the exact candidate SHA, current base and required-check names/provider/conclusions. Recheck successor PRs after earlier merges; never waive a failing required check.
2. Keep action references at full commit SHAs and review their provenance and nested dependencies. Verify a real hosted run after policy or workflow changes, including continued default CodeQL operation; do not add duplicate advanced CodeQL setup.
3. Read back the effective main rules and environment settings after authorized changes. Keep Sonar optional until its separate calibration and secure PR-analysis criteria are met.
4. Before an authorized release, recheck the `release` environment's human reviewer, main-only branch policy and secure signing credentials. Self-review remains allowed and existing administrator bypass remains enabled; neither is release authorization. The published Beta Release workflow already uses this environment.

Secret scanning, push protection and Dependabot security updates remain enabled. Default CodeQL extended analysis covers Actions, Python and Swift. Dependabot's configuration excludes npm rewrites inside the frozen vendor snapshot; updates there require explicit integrity and attribution review.

The release workflow retains validated evidence for 90 days and exports GitHub's source SPDX inventory through the asynchronous generation/fetch API. The exporter waits for a bounded interval and labels the result as a current repository-graph snapshot, not an inventory bound to the candidate SHA. The deprecated synchronous endpoint retires November 13, 2026 and is not used by the workflow. This does not supply signing credentials, prove notarization, or create a distributable artifact. [GitHub SBOM API](https://docs.github.com/en/rest/dependency-graph/sboms). Attestation preparation and remaining evidence are in [RELEASE.md](RELEASE.md) and [DEPENDENCIES.md](DEPENDENCIES.md).

## Optional independent review

Default to a fresh Codex review of the intended diff. CodeRabbit has not been installed. If the owner chooses a later repository-only OSS pilot, first verify eligibility and granted permissions in its UI, disable autonomous code changes/merges and paid add-ons, and select only nav-center. Current documentation offers Team features for public OSS without a paid subscription, with 1–10 PR reviews per developer/hour and 100–300 files per review depending on project tier. Public repositories below 10 stars need manually triggered reviews. These are eligibility-dependent limits, not a guaranteed allocation for this repository. [Current CodeRabbit plans and limits](https://docs.coderabbit.ai/management/plans).

Pilot acceptance: compare a few representative PRs against existing Codex/CodeQL/Sonar findings; record unique actionable findings, false positives, review latency and actual cost. Keep it only if the additional signal justifies the permissions and maintenance. Do not add another AI reviewer, a paid upgrade, or automatic approval authority by default.
