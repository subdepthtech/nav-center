# Friends and Family Beta

Nav Center beta builds are local-first macOS builds for trusted testers. The app keeps job-search data, imported documents, diagnostics, and generated feedback drafts on the tester's Mac.

## Install

Apple silicon (arm64) only in this beta; Intel is not supported.

Download the DMG and its `.sha256` from the GitHub prerelease, then verify the download:

```sh
shasum -a 256 -c NavCenter-<version>-macos-arm64.dmg.sha256
```

The public `subdepthtech/nav-center` Homebrew tap is an alternative install of that same prerelease:

```sh
brew tap subdepthtech/nav-center
brew install --cask nav-center
```

1. Open the beta DMG.
2. Drag `Nav Center.app` to `/Applications`.
3. Launch the app.
4. On first launch, Nav Center creates its workspace at:

```text
~/Library/Application Support/Nav Center/Workspace
```

The workspace contains:

```text
applications/
master-resumes/
tracking/
imports/originals/
imports/markdown/
backups/
logs/
feedback/
```

## First Run

Use the Overview setup panel to import resumes, evaluations, education records, certifications, and related documents. Nav Center copies originals into `imports/originals/` and creates reviewable Markdown copies in `imports/markdown/`.

Do not treat generated resume data as final until the imported Markdown and `master-resumes/master_primary.yaml` have been reviewed.

## Codex Plugin Skills

Install the `Nav Center` plugin from the Codex marketplace to make the beta helper skills available from this public repository. The plugin package lives at `plugins/nav-center` so marketplace installation only receives the skill files, not the full app source tree.

For development from a source checkout, install the same packaged skills directly with:

```sh
scripts/install-codex-skills.sh
```

Installed skills:

- `nav-center-codex-setup`: setup, workspace init, doc intake, master resume review, Codex checks, and paused automation setup.
- `nav-center-beta-feedback`: draft feedback for Austin without auto-sending.

## Feedback

Run:

```sh
/Applications/Nav\ Center.app/Contents/MacOS/navcenterctl feedback-diagnostics --redact
```

Use the `nav-center-beta-feedback` skill to turn the issue, expected behavior, actual behavior, steps, screenshots you approve, and redacted diagnostics into a send-ready Markdown draft.

Feedback drafts should not include private resume content, exact private file paths, account data, tracker databases, or unapproved attachments.

## Known Beta Limits

- PDF and DOCX import keeps originals and creates review notes; rich extraction may require manual paste/review.
- The Homebrew tap is an alternative to the GitHub prerelease DMG. The `0.1.0-beta` cask's caveat claimed notarization that its release notes said was still pending; casks from `0.1.0-beta.1` on are generated only from accepted notarization evidence.
- The nightly job-package automation is created paused by default.
- Codex package edits require explicit user confirmation.

## Uninstall

1. Quit Nav Center.
2. Move `/Applications/Nav Center.app` to Trash.
3. Optional data removal. The workspace directory is `~/Library/Application Support/Nav Center`:

```sh
rm -rf "$HOME/Library/Application Support/Nav Center"
rm -f "$HOME/Library/Preferences/com.subdepthtech.navcenter.plist"
rm -rf "$HOME/Library/Saved Application State/com.subdepthtech.navcenter.savedState"
```

`~/Library/Preferences/com.subdepthtech.navcenter.plist` and `~/Library/Saved Application State/com.subdepthtech.navcenter.savedState` are AppKit window state only; may not exist.

A vault mirror directory you chose (NAV_CENTER_VAULT_DIR) is yours and is never removed.
