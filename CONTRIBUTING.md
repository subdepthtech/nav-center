# Contributing

Thanks for considering a contribution.

## Local Checks

Run these before opening a pull request:

```sh
swift test
swift build
git diff --check
```

Use the supported Xcode selection and disposable scratch paths in [testing](docs/TESTING.md). Read [repository guidance](AGENTS.md), [architecture](docs/ARCHITECTURE.md), and [tooling operations](docs/TOOLING.md) for checks, tool pins, and private-data boundaries. Formatting and SwiftLint begin as explicit advisory baselines; native tests and release regressions remain required. Do not bulk-reformat unrelated or inherited work.

Open a ready-for-review PR with the relevant checks, failures, and integration skips. Use Issues for bounded changes with acceptance criteria. Human maintainers decide merges and releases; no bot approval or auto-merge is configured.

## Development Rules

- Keep the app local-first and privacy-preserving.
- Do not add sample data that contains real names, emails, phone numbers, addresses, application history, or generated private artifacts.
- Keep mutating actions behind explicit user confirmation.
- Prefer small, focused changes with tests for path handling, model decoding, and workflow actions.

## Public Data Policy

Only synthetic sample data belongs in this repository. Real job postings, tailored resumes, tracker databases, vault files, and generated PDFs/DOCX files should stay in a private workspace.
