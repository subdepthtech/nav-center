# Friends and Family Beta

Nav Center beta builds are local-first macOS builds for trusted testers. The app keeps job-search data, imported documents, diagnostics, and generated feedback drafts on the tester's Mac.

## Install

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

## Codex Skills

From the source tree, install the beta helper skills with:

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
- Homebrew installs use the public `subdepthtech/nav-center` tap.
- The nightly job-package automation is created paused by default.
- Codex package edits require explicit user confirmation.

## Uninstall

1. Quit Nav Center.
2. Move `/Applications/Nav Center.app` to Trash.
3. Optional data removal:

```sh
rm -rf "$HOME/Library/Application Support/Nav Center"
rm -f "$HOME/Library/Preferences/com.subdepthtech.navcenter.plist"
```
