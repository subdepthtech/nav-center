# Changelog

## 0.1.0-beta.1 (unreleased)

- Known limit: Live voice interviews are not included in 0.1.0-beta.1. Realtime Interview currently creates a local session kit for an external client; it does not start audio or call a model.
- The minimum supported macOS is now 26 (support follows the latest two major releases); CI and release builds run on macos-26 with Xcode 26.6.
- Ship LICENSE and third-party notices in the app bundle and DMG; distribution builds refuse an unconfirmed notice.
- Name the missing tool, its environment variable and an install hint when atsim, the export tools, Ruby or Codex are unavailable; `navcenterctl doctor` and Settings show every external tool; feedback diagnostics are redacted by default.
- Cleanup review lists every package before removal and refuses trackers with custom triggers before moving anything.
- Release verification checks the mounted app, notices and version strings; the Homebrew cask is generated only from accepted notarization evidence.
- Extracted Nav Center into a standalone SwiftPM macOS app source tree.
- Added public release scaffolding, CI, security guidance, and synthetic sample workspace data.
- Fixed child-process signalling so a reaped process-group leader is never signalled again, while descendant cleanup, cooperative cancellation and bounded timeouts are preserved.
- Fixed document export rejecting `@media` queries: CSS function tokens now require an adjacent `(` per CSS Syntax Level 3, without widening the function allowlist.
- Fixed importing a document whose parent directory is a symlink. Workspace-root symlink rejection is unchanged.
- A tracker that cannot be read now degrades to a package-only view with a warning instead of blanking the dashboard, and tracker writes are disabled while it is unreadable.
- Fixed tracker status changes binding colliding package IDs to the wrong application directory.
- Fixed a failed first tracker status action leaving an unusable database; correcting the package now allows a retry without losing status or history atomicity.
- Quitting with unsaved master resume edits can now be completed via Save, and `restore-cleanup` reports what was actually restored.
- Fixed the SBOM export treating a pending `202` report as a failure and a delivered but invalid report as pending; retries stay bounded.
- CI whitespace and conflict-marker checks now inspect the committed range for the triggering event, including merge resolutions, instead of an always-empty working-tree diff.
- Release artifacts upload with a predictable layout, a failed notarization no longer wedges later attempts, and an interrupted tool download no longer blocks reruns.
