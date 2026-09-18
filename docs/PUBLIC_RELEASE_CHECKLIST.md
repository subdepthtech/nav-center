# Public Release Checklist

Use this before making the repository public or publishing binaries.

## Must Pass

- `swift test --enable-code-coverage`
- `swift build`
- `swift build -c release`
- Supported address and thread sanitizer runs
- `git log --format= --check --diff-merges=remerge <range>` over the committed range, and `git diff --check` for uncommitted work
- `for script in scripts/*.sh; do bash -n "$script"; done`
- `python3 -B -m unittest discover -s scripts/tests -v`
- Secret scan over the current tree
- Private-data scan over source, docs, tests, examples, assets, and git history

## Current Extraction Boundary

Included:

- Swift source under `Sources/`
- XCTest coverage under `Tests/`
- App icon source under `Resources/`
- Synthetic sample workspace files
- Public docs, license, contribution guide, security guide, and CI
- Friends and family beta docs, release scripts, and Codex skill sources

Excluded:

- Private application packages
- Private resumes and cover letters
- Tracker SQLite databases
- Generated PDFs, DOCX, HTML, text extracts, and build products
- Vault mirrors and local Codex/session files
- GitHub remote setup

## Before Public GitHub

1. Initialize a fresh git history from this extracted tree.
2. Run a current-tree secret scan.
3. Run a history scan after the initial commit.
4. Confirm the license choice.
5. Confirm the bundle identifier and signing/notarization plan.
6. Add release screenshots only after checking them for private data.
7. Create the GitHub repository only after the extracted tree is clean.

## Release Artifact Contract

Recommended artifact names:

```text
NavCenter-0.1.0-beta.1-macos-arm64.dmg
NavCenter-0.1.0-beta.1-macos-arm64.dmg.sha256
NavCenter-0.1.0-beta.1-macos-arm64.dmg.notary.json
```

Use the distribution gates in [RELEASE.md](RELEASE.md). The workflow fails if required secrets, preinstalled Gitleaks, either hygiene scan, signing, notarization, stapling, or artifact validation fails. Configure the release environment and runner before attempting it. Source-only CI or offline dependency-stub tests do not establish trusted distribution readiness.

Before publishing, retain evidence for the exact downloaded artifact: final checksum, app version/build, Developer ID signature and nested-code validation, accepted notarization result, staple validation, Gatekeeper acceptance, and offline launch on clean machines for every advertised architecture and minimum supported macOS. Verify upgrades and explicit uninstall/zap scope using disposable data. Never publish `-unsigned.dmg` outputs.

Friends/family beta releases should stay prerelease until beta feedback and privacy checks pass.
