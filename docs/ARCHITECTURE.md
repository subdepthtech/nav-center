# Architecture

Nav Center is a native macOS application and companion CLI for local job-application workspaces. The source currently supports package review and creation, master-resume editing, tracker updates, document import/export, interview preparation, cleanup/recovery, and an optional Codex panel. It does not implement a web backend or application-submission service. This describes the current source, not release acceptance.

## Compiler and package boundaries

[`Package.swift`](../Package.swift) uses Swift tools 5.9, declares macOS 26 as the deployment minimum (`.macOS("26.0")`), and has no third-party Swift package dependencies.

| Target / product | Responsibilities | Dependencies and platform boundary |
| --- | --- | --- |
| [`NavCenterCore`](../Sources/NavCenterCore), library | Workspace paths and files, SQLite tracker, package actions, imports/exports, cleanup/recovery, interview material, diagnostics | Foundation, Darwin, system SQLite3, CryptoKit, and external process execution. Shared by the app and CLI; it is not currently a cross-platform library. |
| [`NavCenterApp`](../Sources/NavCenterApp), executable | SwiftUI views, AppKit lifecycle, PDF previews, dashboard state/services, Codex protocol and staged package edits | `NavCenterCore`, SwiftUI, AppKit, PDFKit and macOS process services. |
| [`NavCenterCLI`](../Sources/NavCenterCLI/main.swift), `navcenterctl` executable | Workspace initialization/diagnostics, imports, package creation, export, redacted feedback and confirmed cleanup restoration | `NavCenterCore`. Argument validation occurs before workspace-changing operations. |
| [`NavCenterTests`](../Tests/NavCenterTests), test target | Core behavior, dashboard state, protocol, path/data safety and optional integrations | Imports both Core and App. XCTest plus macOS facilities; some tests also execute the sibling built CLI. |

[`NativeDashboardService`](../Sources/NavCenterApp/Services/NativeDashboardService.swift) adapts Core operations to the app's models. [`DashboardStore`](../Sources/NavCenterApp/Stores/DashboardStore.swift) owns UI state, asynchronous refreshes and confirmations. Names such as `DashboardAPIError` do not imply a deployed HTTP API. [`NativeCodexBridge`](../Sources/NavCenterApp/Services/NativeCodexBridge.swift) and [`CodexPackageEditBroker`](../Sources/NavCenterApp/Services/CodexPackageEditBroker.swift) remain app services, rather than Core dependencies.

## Workspace and private data

[`WorkspaceManager`](../Sources/NavCenterCore/WorkspaceManager.swift) defaults to `~/Library/Application Support/Nav Center/Workspace`. `NAV_CENTER_WORKSPACE_ROOT` overrides it; the CLI also accepts `--workspace`. This workspace is separate from the source checkout. When testing the development bundle, explicitly select a disposable workspace; see [Testing](TESTING.md).

| Workspace-relative path | Contents |
| --- | --- |
| `applications/<package>/` | Posting, resume/cover-letter Markdown, notes, interview material and `artifacts/` outputs, including ATS reports |
| `master-resumes/master_primary.yaml` | Reviewed source resume used by local workflows |
| `tracking/applications.sqlite` | Tracker records and status history; package-only views still work without a database |
| `tracking/applications.md` | Derived tracker snapshot, not the authoritative database |
| `imports/originals/`, `imports/markdown/`, `imports/manifest.jsonl` | Retained inputs, review copies and import provenance; the manifest can contain original local paths |
| `templates/`, `output/` | Document styles and non-package export outputs |
| `backups/`, `logs/`, `feedback/`, `tmp/` | Operational files and potentially private diagnostics, staging or recovery evidence |
| `tmp/package-cleanup/<operation>/` | Cleanup manifest, retained package files and tracker backup needed for recovery |

Real resumes, application history, databases, transcripts, generated documents, vault mirrors and account data must stay outside the public repository and CI uploads. Tests create synthetic temporary workspaces. Diagnostic redaction is a bounded feature, not permission to publish arbitrary logs or workspace contents.

[`DocumentImporter`](../Sources/NavCenterCore/DocumentImporter.swift) retains originals and creates Markdown review copies. It decodes supported UTF-8 text formats; other formats receive an extraction-unavailable notice. The current beta does not provide general PDF/DOCX extraction or OCR through this importer.

## Local operations and optional integrations

The app, CLI, and diagnostics share one resolver, [`ToolProbe`](../Sources/NavCenterCore/ToolAvailability.swift). Probing never executes a tool. A slash-containing override must be an absolute path, and PATH or fallback entries that are not absolute are skipped.

| Integration | Current use and boundary |
| --- | --- |
| System Ruby | [`MasterResumeStore`](../Sources/NavCenterCore/MasterResumeStore.swift) validates YAML through a bounded subprocess. Ruby is resolved on PATH, then in `/opt/homebrew/bin`, `/usr/local/bin`, and `~/.local/bin`. The probe checks for an executable regular file and never executes Ruby. A missing Ruby fails before any candidate file is written; the validator runs only after Ruby is found. |
| Pandoc, Chrome, Poppler | [`ArtifactExporter`](../Sources/NavCenterCore/ArtifactExporter.swift) produces HTML, DOCX, PDF and extracted text. Overrides are `PANDOC_BIN`, `CHROME_BIN` and `PDFTOTEXT_BIN`, then PATH, then `/opt/homebrew/bin`, `/usr/local/bin`, and `~/.local/bin`. Chrome's default is the `/Applications` bundle path. The probe never executes these tools; `--version` checks stay behind a confirmed export. Pandoc must support `--sandbox`; Chrome renders inert content using a separate profile and retains its sandbox. |
| External `atsim` | [`PackageActionRunner`](../Sources/NavCenterCore/PackageActionRunner.swift) resolves `NAV_CENTER_ATSIM_BIN`, then `atsim` on PATH, then `/opt/homebrew/bin`, `/usr/local/bin`, and `~/.local/bin`. The probe checks for an executable regular file and never executes `atsim`. A confirmed scan stages only required synthetic/user-selected package inputs and sets `ATSIM_JOB_HUNT_ROOT` to that staging workspace. A successful command must also produce a valid fresh report. |
| External exporter | `NAV_CENTER_EXPORT_BIN` can replace the built-in confirmed package export action with a compatible executable. When it is unset, the built-in exporter is used. An override is resolved the same way (environment, then PATH, then `/opt/homebrew/bin`, `/usr/local/bin`, and `~/.local/bin`) and is not executed until the action is confirmed. |
| Vault copy | [`VaultSync`](../Sources/NavCenterCore/VaultSync.swift) copies a validated package set to an explicit local vault root. Exports may invoke it when `NAV_CENTER_VAULT_DIR` is configured; `NAV_CENTER_SKIP_VAULT_SYNC=1` suppresses that export-time copy. |
| Posting URL capture | [`ApplicationCreator`](../Sources/NavCenterCore/ApplicationCreator.swift) performs an explicit HTTP(S) request through curl with address and redirect restrictions. Pasted or local posting text avoids that request. |
| Codex | The app launches `codex app-server --listen stdio://`. [`NativeCodexBridge`](../Sources/NavCenterApp/Services/NativeCodexBridge.swift) resolves that command with `ToolProbe` on every launch: `DASHBOARD_CODEX_BIN`, then absolute PATH entries, then `/opt/homebrew/bin`, `/usr/local/bin`, and `~/.local/bin`. Only that absolute found path is executed. A missing Codex or an invalid `DASHBOARD_CODEX_BIN` refuses with the same missing-tool message as the other actions and does not run the override or the bare name `codex`. Probing never executes Codex. Sign-in and package edit approval are separate. Requests and selected context are processed by the services used by the signed-in account; local stdio transport does not make model processing offline. |

[`RealtimeInterviewKitGenerator`](../Sources/NavCenterCore/RealtimeInterview.swift) writes session configuration, a transcript template and a review prompt. Generating those files does not establish a live realtime session, microphone integration or a backend.

Package writes pass through [`PathSafety`](../Sources/NavCenterCore/PathSafety.swift), while [`TrackerStore`](../Sources/NavCenterCore/TrackerStore.swift) uses SQLite transactions. [`PackageCleanup`](../Sources/NavCenterCore/PackageCleanup.swift) binds destructive cleanup to a preview and keeps recovery evidence. The Codex edit broker uses isolated staging, allowlisted Markdown, identity checks and conflict detection before committing approved edits. These controls are implemented source behavior; coordinated filesystem writes are not power-loss atomic and userspace checks do not eliminate every hostile concurrent ancestor rename. See [README safety model](../README.md#safety-model) and the corresponding [tests](TESTING.md).

## Vendored ATS snapshot

[`vendor/atsim`](../vendor/atsim/UPSTREAM.md) is an unchanged review snapshot of `austinkennethtucker/cli` at `cc37c5b1e3a4f7dfe17d9f043eb18021ff6faef4` (package version 0.1.0). It is not linked, bundled or activated by `Package.swift`; runtime ATS still uses the external executable. [`UPSTREAM-SHA256.json`](../vendor/atsim/UPSTREAM-SHA256.json) records the copied file hashes. Updates must be explicit, with integrity and security review; dependency bots must not silently rewrite the snapshot.

Upstream declares MIT in its package metadata, but the snapshot records that no standalone license notice was available at that revision. Attribution/license completion remains a distribution prerequisite. Upstream machine-specific install paths are not Nav Center setup instructions. Maintained-code analysis should exclude this snapshot while retaining a separate inventory and integrity review.

## Build and distribution boundary

SwiftPM builds the products. [`scripts/build-and-run.sh`](../scripts/build-and-run.sh) assembles the app bundle and embedded CLI; the release scripts produce a host-architecture DMG with separate unsigned-local and signed-distribution modes. There is no current App Store submission target. Debug/test success, static analysis, and stubbed release regressions do not establish signing, notarization, clean-device behavior or production readiness. Follow [Testing](TESTING.md), [Release](RELEASE.md), and the [public release checklist](PUBLIC_RELEASE_CHECKLIST.md).
