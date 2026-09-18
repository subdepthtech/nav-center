# Repository guidance

- Read `docs/ARCHITECTURE.md` for target boundaries and `docs/TESTING.md` for the checks relevant to a change. Tooling operations and outstanding setup gates are in `docs/TOOLING.md` and `docs/SETUP.md`.
- Preserve existing dirty and untracked work. Keep changes scoped; do not include someone else's implementation in a commit or PR without authorization.
- Use synthetic fixtures and temporary workspaces. Never read real resumes, application history, vaults, credentials, or Codex authentication files as test data.
- Keep package writes confined, confirmation requirements intact, and external processes bounded. Add regression coverage for changed safety behavior; do not weaken tests to obtain a passing check.
- Prefer existing functionality and small configuration changes. The package currently targets macOS; a backend, ATS port, or product rewrite requires separate scope.
- Keep GitHub Actions least privilege and pinned to full commit SHAs. Never put secrets in source, reports, issue text, or logs. External analysis must contain vetted repository source only.
- Treat `vendor/atsim` as a fixed review snapshot. Verify `UPSTREAM-SHA256.json`; updates and attribution require explicit review, not dependency-bot rewriting.
- Native tests, optional external integrations, GUI/accessibility checks, and signed distribution evidence are separate gates. Report failures and skips accurately.
- Maintain human merge and release authority. PRs must be ready for review, never drafts; do not merge, distribute, or submit to Apple without explicit authorization.

`AGENTS.local.md` is ignored personal guidance. It does not replace this shared policy or a user's explicit task boundaries. `plan.md` is historical context, not standing implementation authority.
