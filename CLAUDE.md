# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Nav Center is a native macOS (13+) SwiftUI app plus a CLI (`navcenterctl`) for reviewing local job-application packages, tracker status, and interview prep. It is local-only: no network service, no application submission. The only outbound traffic is the optional Codex panel (via the Codex CLI `app-server`) and explicit posting-URL capture. This is a public beta extraction of a private workflow; private resumes, tracker databases, and generated PDFs must never land in the repo (see `.gitignore` and `docs/PUBLIC_RELEASE_CHECKLIST.md`).

## Commands

```sh
swift build                          # debug build of all targets
swift build -c release
swift test                           # all XCTest targets
swift test --filter PluginManifestTests            # one test class
swift test --filter DashboardParityTests/testStoreLoadsAndSavesMasterResumeContent   # one test
scripts/build-and-run.sh [run|build|--debug|--logs|--verify]   # stage dist/Nav Center.app and launch
```

Dev workspace: the app reads `NAV_CENTER_WORKSPACE_ROOT` (default is `~/Library/Application Support/Nav Center/Workspace`). The repo root itself is a synthetic sample workspace (`applications/`, `master-resumes/`, `tracking/`), so for dev runs:

```sh
NAV_CENTER_WORKSPACE_ROOT=$PWD NAV_CENTER_INCLUDE_WORKSPACE_ENV=1 scripts/build-and-run.sh
```

CLI black-box tests and release-script tests are Python, not XCTest:

```sh
NAVCENTERCTL="$(swift build --show-bin-path)/navcenterctl" python3 -B scripts/tests/test_cli.py -v
python3 -B -m unittest discover -s scripts/tests -v     # release scripts, fully stubbed/offline
```

The full CI gate (`.github/workflows/ci.yml`) also runs `git log --format= --check --diff-merges=remerge <range>` over the committed range, `bash -n scripts/*.sh`, and `swift test --sanitize=address` / `--sanitize=thread` with separate `--scratch-path`s. That committed-range check is not `git diff --check`, which only inspects the working tree and passes on a clean checkout. Run those before claiming release readiness.

Packaging: `NAV_CENTER_VERSION=0.1.0-beta.1 NAV_CENTER_BUILD=1 scripts/package-beta-dmg.sh --local` produces an unsigned DMG; `--distribution` requires signing/notarization secrets and Gitleaks (see `docs/RELEASE.md`). Never treat an `-unsigned.dmg` as distributable.

## Architecture

Three SwiftPM targets, one test target (`Package.swift`):

- **`NavCenterCore`** (library, `Sources/NavCenterCore`): all filesystem, SQLite, and subprocess logic. No AppKit/SwiftUI. Everything public here is consumed by both the app and CLI. Key pieces:
  - `PathSafety` is the security boundary. Every path that touches `applications/<package>/` goes through `resolvePackage`, `assertNoSymlinkSegments`, `realpath`, `identity` (dev/inode checks), and `atomicWrite`. New file operations must use these helpers rather than raw `FileManager` calls.
  - `WorkspaceManager` resolves the workspace root and seeds required dirs and `master-resumes/master_primary.yaml`.
  - `PackageInspector` scans packages into `ApplicationPackage` (files, tabs, health); `TrackerStore` wraps `tracking/applications.sqlite` via the system SQLite3 module (tracker is optional; packages without rows are "package-only").
  - `PackageActionRunner` runs confirmation-gated actions (`ats-scan`, resume export). ATS runs in a private `mkdtemp` staging copy and results are copied back. External tools are located via `NAV_CENTER_ATSIM_BIN` / `NAV_CENTER_EXPORT_BIN`.
  - `PackageCleanup` writes a manifest + tracker backup; `navcenterctl restore-cleanup` reverses it and refuses changed evidence.
  - `ArtifactExporter`, `DocumentImporter`, `MasterResumeStore`, `InterviewPrep`, `RealtimeInterview`, `VaultSync`, `FeedbackDiagnostics` are the remaining feature modules; all validate complete output sets and roll back on ordinary write failure.
- **`NavCenterApp`** (SwiftUI executable, `Sources/NavCenterApp`):
  - `DashboardStore` (`@MainActor ObservableObject`) is the single source of UI state. It talks only to the `DashboardServicing` protocol and dispatches work onto two serial queues: `serviceQueue` for local ops and `codexQueue` for Codex. Tests inject fake services via `DashboardStore(service:)`.
  - `NativeDashboardService` is the production `DashboardServicing`. It composes Core types (`PackageInspector`, `PackageActionRunner`, `TrackerStore`, etc.) and converts them into the app-side `DashboardModels` (`DashboardSummary`, `ApplicationRecord`, `PackageResponse`, …). The app-side models mirror a previous web dashboard's JSON shape; `DashboardParityTests` pins navigation sections, action rails, and status buttons to that contract.
  - `NativeCodexBridge` owns the Codex `app-server --listen stdio://` child process (one per workspace root, JSON-RPC over stdio). It starts threads/turns, queues approval requests, and enforces sandbox policy. When a chat allows edits, `CodexPackageEditBroker` copies the package's allowed markdown into a `0700` staging dir, Codex edits only the staging copy, and `applyValidatedChanges` copies back after re-checking baseline content and dir identities. The server is stopped before staging is validated so nothing retains write authority.
  - Views (`ContentView`, `ApplicationsView`, `PackageDetailView`, `CodexPanelView`, `OverviewView`, `SharedViews`) are thin over the store. `StatusActions` defines tracker quick actions.
- **`NavCenterCLI`** (`navcenterctl`, `Sources/NavCenterCLI/main.swift`): `init-workspace`, `doctor`, `import-docs`, `create-package`, `export-artifacts`, `feedback-diagnostics`, `restore-cleanup`. `ArgumentParser.validate` rejects the whole invocation before any I/O or workspace resolution; keep that property when adding flags.

## Conventions worth knowing

- Mutating actions require an explicit `confirmed: true` / UI confirmation; unconfirmed calls are logged as `blocked`, not silently run. Cleanup requires the exact displayed preview to match.
- Tests are named `*ReadinessTests`, `*SecurityTests`, `*IntegrityTests`, and build disposable workspaces under `temporaryDirectory`. Use `@testable import NavCenterApp` / `NavCenterCore` and inject `DashboardServicing` fakes rather than touching the real workspace. Never point tests at the real Application Support workspace.
- Package names are `YYYY-MM-DD_Company_Role` directories under `applications/`; `posting.md` frontmatter supplies metadata.
- Env vars: `NAV_CENTER_WORKSPACE_ROOT`, `NAV_CENTER_ATSIM_BIN`, `NAV_CENTER_EXPORT_BIN`, `NAV_CENTER_VAULT_DIR`, `NAV_CENTER_SKIP_VAULT_SYNC`, and the `NAV_CENTER_VERSION` / `NAV_CENTER_BUILD` / `NAV_CENTER_DIST_DIR` / `NAV_CENTER_BUILD_CONFIGURATION` packaging knobs.
- `plugins/nav-center` is the public Codex/Claude plugin containing only the two `SKILL.md` files; `PluginManifestTests` checks both plugin manifests and `.agents/plugins/marketplace.json`. `scripts/install-codex-skills.sh` installs them into `~/.codex/skills` for local dev.
- `vendor/atsim` is an unchanged upstream source snapshot for review only; the app still shells out to an external `atsim` binary and does not build or import this directory.
- `AGENTS.md` is shared repository guidance; `AGENTS.local.md` is ignored personal guidance.
