# Nav Center

Native macOS app for reviewing local job-application packages, generated artifacts, tracker status, interview prep, and confirmation-gated workflow actions.

Nav Center stores its workspace on disk and binds no public network service. It does not submit applications or send outreach. The optional Codex panel sends messages and selected package context to the services used by your signed-in Codex account. Posting URL capture makes an explicit HTTP request; paste a posting instead to avoid that request.

## Status

This is a beta source tree extracted from a private workflow. The repository contains source code, tests, public docs, beta setup skills, release scripts, and a small synthetic sample workspace only. Production distribution still requires the evidence in the release checklist. Private resumes, application history, tracker databases, vault mirrors, generated PDFs, and local account data must stay outside the public repository.

## Requirements

- macOS 13 or later
- Swift 5.9 or later
- System SQLite library for tracker-backed views (no `sqlite3` command required)
- System Ruby for bounded, safe master-resume YAML validation
- Optional: Pandoc with `--sandbox` support, Google Chrome, and Poppler `pdftotext` for document export
- Optional: [`atsim` 0.1.0](https://github.com/austinkennethtucker/cli/tree/cc37c5b1e3a4f7dfe17d9f043eb18021ff6faef4/atsim) (Python 3.10+) for the confirmed ATS scan action. Install that package from the CLI repository into an isolated Python environment; expose its `atsim` launcher on PATH or set `NAV_CENTER_ATSIM_BIN` to its absolute path. Nav Center supplies the scan workspace and requires a report containing `scores.overall` and `warnings`.
- Optional: `NAV_CENTER_EXPORT_BIN` to override the built-in confirmed resume export action with a compatible external exporter
- Optional: Codex CLI with app-server support and managed sign-in for the in-app Codex panel

## Build

Development guidance: [architecture](docs/ARCHITECTURE.md), [testing](docs/TESTING.md), [tooling runbook](docs/TOOLING.md), and [setup status](docs/SETUP.md). Shared agent policy is in [AGENTS.md](AGENTS.md).

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

## Codex Plugin Skills

Nav Center publishes its beta helper skills as a Codex plugin from this public repository. The marketplace plugin root is [`plugins/nav-center`](plugins/nav-center), which keeps the installable package limited to the skill manifests and skill files.

Install the `Nav Center` plugin marketplace for the Codex app with:

```sh
codex plugin marketplace add subdepthtech/nav-center
```

Then open Codex and enable the `Nav Center` plugin from the plugin marketplace. The plugin provides:

- `nav-center-codex-setup`: first-run setup, workspace preparation, document intake, master resume review, Codex connection checks, and paused automation setup.
- `nav-center-beta-feedback`: redacted beta feedback and diagnostic report drafting.

For development from a source checkout, install the same packaged skills directly with:

```sh
scripts/install-codex-skills.sh
```

## Homebrew Install

Beta builds are distributed through the public `subdepthtech/nav-center` Homebrew tap:

```sh
brew tap subdepthtech/nav-center
brew install --cask nav-center
```

Do not pass the `git@github.com:subdepthtech/homebrew-nav-center.git` SSH URL unless the tester has SSH access configured for that repo. The one-argument tap command above uses GitHub over HTTPS.

For a private or local cask file generated during release prep:

```sh
brew install --cask /path/to/homebrew-tap/Casks/nav-center.rb
```

Upgrade with:

```sh
brew update
brew upgrade --cask nav-center
```

Uninstall the app with:

```sh
brew uninstall --cask nav-center
```

Remove the app and local Nav Center support files with:

```sh
brew uninstall --cask --zap nav-center
```

## Release

Create an unsigned local test DMG with:

```sh
NAV_CENTER_VERSION=0.1.0-beta.1 NAV_CENTER_BUILD=1 scripts/package-beta-dmg.sh --local
```

This produces an `-unsigned.dmg` for local testing. The default distribution mode requires a clean source tree, full-history/current-tree secret scans, Developer ID signing, notarization, and Gatekeeper verification. See [docs/RELEASE.md](docs/RELEASE.md) for runner prerequisites, versioning, and architecture-specific Homebrew casks.

## Safety Model

- Package paths are normalized and constrained to `applications/<package>/`.
- Package previews only read allowlisted markdown, text, JSON, and HTML paths.
- Mutating package actions require explicit UI confirmation.
- Codex markdown edits require explicit sign-in and package-markdown edit approval.
- Generated binaries, PDFs, DOCX files, tracker databases, and local workspaces are ignored by default.
- Document export supports text, headings, lists, tables and local styling. Active HTML, embedded resources, CSS escapes/comments and resource-loading styles are rejected. Chrome uses a fresh private profile with its own sandbox enabled; unsupported converters fail closed.
- Cleanup requires the exact displayed preview and preserves package files plus a consistent tracker backup. Confirmed recovery validates the retained manifest and preserves unrelated later tracking changes. Conflicting or changed backup evidence requires manual review.
- Imports, exports and vault copies validate complete output sets and roll back ordinary write failures. Coordinated filesystem writes are not power-loss atomic, and userspace checks do not prevent every hostile concurrent ancestor rename.

To recover a cleanup, use the manifest reported by that operation:

```sh
navcenterctl restore-cleanup --workspace /path/to/workspace \
  --manifest tmp/package-cleanup/<operation>/manifest.json --confirm
```

Keep the entire operation directory until recovery is complete. Recovery refuses changed or conflicting evidence and never replaces the complete current tracker with an old database.

## Release Readiness

See [docs/PUBLIC_RELEASE_CHECKLIST.md](docs/PUBLIC_RELEASE_CHECKLIST.md) before creating a public GitHub repository or release artifact.
