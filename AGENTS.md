# Nav Center Agent Guide

Nav Center is a standalone SwiftPM macOS app extracted from a private job-application workflow.

## Read Order

1. `README.md`
2. `docs/PUBLIC_RELEASE_CHECKLIST.md`
3. `docs/BETA.md`
4. `docs/RELEASE.md`
5. `SECURITY.md`
6. `Package.swift`

## Commands

```sh
swift test
swift build
scripts/build-and-run.sh --verify
swift run navcenterctl doctor --json
bash -n scripts/*.sh
git diff --check
```

## Change Rules

- Keep source changes independent from any private workspace.
- Do not commit private applications, resumes, tracker databases, generated artifacts, vault mirrors, account data, or local machine paths.
- Keep mutating actions confirmation-gated.
- Keep sample data synthetic.
- Keep beta feedback drafts local and redacted; never auto-send them.
- Do not create a GitHub remote, publish, or push without explicit user approval.
