<!-- Maintainer: publish only after artifact-verification.md, the WP7 and WP8 records, and WP12A pass; replace every {{PLACEHOLDER}}; delete this comment. -->
# Nav Center 0.1.0-beta.1 (friends-and-family beta)

Nav Center is a local-first macOS app for reviewing job-application packages, tracker status, and interview prep. Data stays on the tester's Mac. The only outbound traffic is the optional Codex panel and explicit posting-URL capture.

## Supported

macOS 26 or later, Apple silicon only. Intel is not supported. Tested on macOS 26.6.2 (hosted CI) and macOS 27.0 (maintainer Mac). Clean-machine result: {{WP12A_SUMMARY}}.

## Install

Download `NavCenter-0.1.0-beta.1-macos-arm64.dmg` and its `.sha256` from this release. Verify the download:

```sh
shasum -a 256 -c NavCenter-0.1.0-beta.1-macos-arm64.dmg.sha256
```

Expected result: `OK`. SHA-256: {{DMG_SHA256}}. Open the DMG, drag Nav Center.app to Applications, then launch it. The workspace is created at `~/Library/Application Support/Nav Center/Workspace`.

The DMG is Developer ID signed, notarized by Apple, and stapled. If macOS says the app is damaged or cannot be verified, stop and report it; do not bypass Gatekeeper. The Homebrew tap is not yet updated for this version; use the DMG.

## What's new

- Setup messages name missing tools, their environment variables, and install hints.
- Settings > External Tools and `navcenterctl doctor` show external tool availability.
- Cleanup review lists every package before removal and checks custom triggers.
- Feedback diagnostics are redacted by default.
- Tracker read failures show a package-only view with a warning instead of blanking the dashboard.
- Failed first tracker status actions can be retried after correcting the package.
- Quitting with unsaved master-resume edits can now complete through Save.

## Known limits

- Live voice interviews are not included in 0.1.0-beta.1. Realtime Interview currently creates a local session kit for an external client; it does not start audio or call a model.
- Optional tools are not bundled: atsim, Pandoc, pdftotext from Poppler, Google Chrome, and Codex CLI. Settings > External Tools shows what is missing and how to install it. Export needs Pandoc, pdftotext, and Google Chrome; ATS scan needs atsim.
- PDF/DOCX import keeps originals and creates review notes; rich extraction may need manual review.
- Codex is optional, needs a signed-in Codex CLI, and package edits need explicit confirmation.
- The nightly automation is created paused.

## Feedback (private and redacted)

Send feedback only in the private channel you were invited through, not as a public GitHub issue. Include what you did, what you expected, what happened, and steps to reproduce it. Attach screenshots only if they show no personal data. Add diagnostics from `/Applications/Nav\ Center.app/Contents/MacOS/navcenterctl feedback-diagnostics` (redacted by default) or Help > Copy Redacted Diagnostics. Never use `--include-unredacted` for feedback. Never send resume content, real application details, file paths, account data, or the tracker database.

## Stop and report immediately

Stop and report data loss, a Gatekeeper rejection, or an app that cannot complete its first launch. Distribution pauses until a fix is re-verified.

## Uninstall

1. Quit Nav Center.
2. Move `/Applications/Nav Center.app` to Trash.
3. Optional data removal. `~/Library/Application Support/Nav Center` is the app support directory; it contains the workspace at `…/Nav Center/Workspace`.

```sh
rm -rf "$HOME/Library/Application Support/Nav Center"
rm -f "$HOME/Library/Preferences/com.subdepthtech.navcenter.plist"
rm -rf "$HOME/Library/Saved Application State/com.subdepthtech.navcenter.savedState"
```

`~/Library/Preferences/com.subdepthtech.navcenter.plist` and `~/Library/Saved Application State/com.subdepthtech.navcenter.savedState` are AppKit window state only; may not exist.

A vault mirror directory you chose (NAV_CENTER_VAULT_DIR) is yours and is never removed.
