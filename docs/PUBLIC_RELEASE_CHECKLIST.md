# Public Release Checklist

Use this before making the repository public or publishing binaries.

## Must Pass

- `swift test`
- `swift build`
- `git diff --check`
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
NavCenter-0.1.0-beta-macos-arm64.dmg
NavCenter-0.1.0-beta-macos-arm64.dmg.sha256
```

Do not publish a signed app until Developer ID signing, notarization, stapling, and Gatekeeper validation are wired.

Friends/family beta releases should stay prerelease until beta feedback and privacy checks pass.
