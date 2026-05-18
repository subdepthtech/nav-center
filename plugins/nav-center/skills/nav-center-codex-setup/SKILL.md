---
name: nav-center-codex-setup
description: Use when a friends or family beta user needs first-run Nav Center setup, workspace preparation, app install checks, or Codex connection checks on macOS.
---

# Nav Center Codex Setup

Use this for local-first beta setup. Keep originals on disk, avoid external uploads, and ask before enabling anything persistent.

## Setup Flow

1. Verify the app install first.
   - Prefer `/Applications/Nav Center.app` for beta users.
   - If using a source checkout, run `scripts/build-and-run.sh --verify`.
   - Confirm the app opens and points at the intended `NAV_CENTER_WORKSPACE_ROOT`.

2. Initialize a workspace.
   - Prefer `navcenterctl init-workspace`.
   - Create or verify `applications/`, `master-resumes/`, `tracking/`, `imports/originals/`, `imports/markdown/`, `backups/`, `logs/`, and `feedback/`.
   - Keep private source files outside generated sample data.
   - Do not import, move, or delete originals without explicit approval.

3. Intake materials by category.
   - Resumes: current resume, prior variants, LinkedIn export, portfolio notes.
   - Evaluations: performance reviews, recommendation letters, feedback.
   - Education: transcripts, coursework, degree notes.
   - Certifications: cert PDFs, badges, renewal dates.
   - Documents: job targets, project writeups, writing samples.

4. Create local Markdown copies.
   - Prefer `navcenterctl import-docs --file <path>` for approved source files.
   - Originals belong in `imports/originals/`; reviewable Markdown belongs in `imports/markdown/`.
   - Mark uncertain OCR or conversion text as `needs review`.
   - Never upload private resumes, PDFs, DOCX files, or screenshots unless the user explicitly asks.

5. Generate the master resume review-first.
   - Draft a review file before changing `master-resumes/master_primary.yaml`.
   - Include only claims traceable to intake Markdown or user-approved facts.
   - Ask the user to approve additions, metrics, titles, dates, and skills before promoting the draft.

6. Check Codex connectivity.
   - Confirm Codex Desktop is signed in if the in-app Codex panel is needed.
   - Check the Codex app-server or Nav Center Codex status panel when available.
   - Do not store API keys, session cookies, or account tokens in the workspace.

7. Offer paused automation setup.
   - Offer the `Nav Center Nightly Job Package Pipeline` paused Codex App automation.
   - Leave automation paused by default and enable it only after explicit confirmation.

## Safety Defaults

- Work locally and keep beta data private.
- Explain every file you create or modify.
- Prefer drafts and review notes over replacing canonical files.
- Stop before sending messages, enabling automation, or sharing private files.
