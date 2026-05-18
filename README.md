# Nav Center

Native macOS app for reviewing local job-application packages, generated artifacts, tracker status, interview prep, and confirmation-gated workflow actions.

Nav Center is local-first. It reads a workspace on disk, binds no public network service, and does not submit applications, send outreach, scrape job boards, upload private files, or mutate external accounts.

## Status

This is an extracted public-ready source tree from a private workflow. The next release target is a friends and family beta. The repository contains source code, tests, public docs, beta setup skills, release scripts, and a small synthetic sample workspace only. It does not include private resumes, application history, tracker databases, vault mirrors, generated PDFs, or local account data.

## Requirements

- macOS 13 or later
- Swift 5.9 or later
- `sqlite3` for tracker-backed views
- Optional: `atsim` for the confirmed ATS scan action
- Optional: `NAV_CENTER_EXPORT_BIN` for any future confirmed resume export action
- Optional: Codex Desktop app-server for the in-app Codex panel

## Build

```sh
swift build
swift test
scripts/build-and-run.sh
```

The app bundle is staged at `dist/Nav Center.app`.

The bundle includes `Contents/MacOS/navcenterctl` for local setup, diagnostics, document import, package creation, and beta feedback support.

## Workspace Layout

Installed builds use this app-owned workspace by default:

```text
~/Library/Application Support/Nav Center/Workspace
```

For development or advanced testing, set `NAV_CENTER_WORKSPACE_ROOT`. When launching through the dev bundle script, set `NAV_CENTER_INCLUDE_WORKSPACE_ENV=1` to embed that override in the staged app bundle:

```sh
NAV_CENTER_WORKSPACE_ROOT=/path/to/workspace NAV_CENTER_INCLUDE_WORKSPACE_ENV=1 scripts/build-and-run.sh
```

A workspace should look like this:

```text
applications/
  2099-01-01_Example_Corp_Security_Engineer/
    posting.md
    Resume_2099-01-01_Example_Corp_Security_Engineer.md
    interview-prep.md
    artifacts/
      ats-report.json
master-resumes/
  master_primary.yaml
tracking/
  applications.sqlite
imports/
  originals/
  markdown/
feedback/
```

`tracking/applications.sqlite` is optional. When it is missing, Nav Center still scans package folders and labels them as package-only records.

## Friends and Family Beta

See [docs/BETA.md](docs/BETA.md) for install, onboarding, feedback, and uninstall guidance.

Install the Codex beta helper skills from a source checkout with:

```sh
scripts/install-codex-skills.sh
```

## Release

Create a private beta DMG with:

```sh
NAV_CENTER_VERSION=0.1.0-beta scripts/package-beta-dmg.sh
```

See [docs/RELEASE.md](docs/RELEASE.md) for signing, notarization, and Homebrew cask steps.

## Safety Model

- Package paths are normalized and constrained to `applications/<package>/`.
- Package previews only read allowlisted markdown, text, JSON, and HTML paths.
- Mutating package actions require explicit UI confirmation.
- Codex markdown edits require explicit sign-in and package-markdown edit approval.
- Generated binaries, PDFs, DOCX files, tracker databases, and local workspaces are ignored by default.

## Release Readiness

See [docs/PUBLIC_RELEASE_CHECKLIST.md](docs/PUBLIC_RELEASE_CHECKLIST.md) before creating a public GitHub repository or release artifact.
