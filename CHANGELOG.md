# Changelog

## Unreleased

- Extracted Nav Center into a standalone SwiftPM macOS app source tree.
- Added public release scaffolding, CI, security guidance, and synthetic sample workspace data.
- Fixed child-process signalling so a reaped process-group leader is never signalled again, while descendant cleanup, cooperative cancellation and bounded timeouts are preserved.
- Fixed document export rejecting `@media` queries: CSS function tokens now require an adjacent `(` per CSS Syntax Level 3, without widening the function allowlist.
- Fixed importing a document whose parent directory is a symlink. Workspace-root symlink rejection is unchanged.
- A tracker that cannot be read now degrades to a package-only view with a warning instead of blanking the dashboard, and tracker writes are disabled while it is unreadable.
- Fixed tracker status changes binding colliding package IDs to the wrong application directory.
- Quitting with unsaved master resume edits can now be completed via Save, and `restore-cleanup` reports what was actually restored.
- Fixed the SBOM export treating a pending `202` report as a failure and a delivered but invalid report as pending; retries stay bounded.
- CI whitespace and conflict-marker checks now inspect the committed range for the triggering event, including merge resolutions, instead of an always-empty working-tree diff.
- Release artifacts upload with a predictable layout, a failed notarization no longer wedges later attempts, and an interrupted tool download no longer blocks reruns.
