# Contributing

Thanks for considering a contribution.

## Local Checks

Run these before opening a pull request:

```sh
swift test
swift build
git diff --check
```

## Development Rules

- Keep the app local-first and privacy-preserving.
- Do not add sample data that contains real names, emails, phone numbers, addresses, application history, or generated private artifacts.
- Keep mutating actions behind explicit user confirmation.
- Prefer small, focused changes with tests for path handling, model decoding, and workflow actions.

## Public Data Policy

Only synthetic sample data belongs in this repository. Real job postings, tailored resumes, tracker databases, vault files, and generated PDFs/DOCX files should stay in a private workspace.
