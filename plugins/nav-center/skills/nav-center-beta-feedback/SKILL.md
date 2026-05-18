---
name: nav-center-beta-feedback
description: Use when drafting Nav Center beta feedback, bug reports, diagnostic summaries, or follow-up messages for friends and family testers.
---

# Nav Center Beta Feedback

Use this to help beta users send clear feedback without exposing private job-search files.

## Feedback Flow

1. Gather the report.
   - Ask for the issue, expected result, actual result, steps to reproduce, and whether it blocks the user.
   - Include app version/build, macOS version, workspace path type, and whether Codex was signed in.

2. Add redacted diagnostics.
   - Run `navcenterctl feedback-diagnostics --redact` when available.
   - If the command is missing, say that and continue with manual details.
   - Review the output for names, emails, exact file paths, tokens, and resume content before including it.

3. Draft only.
   - Never auto-send email, text, LinkedIn, Slack, or GitHub messages.
   - Do not attach or upload resumes, PDFs, screenshots, logs, databases, or workspace archives unless the user explicitly approves that exact file.

## Send-Ready Draft

```text
Subject: Nav Center beta feedback: <short issue>

Hi Austin,

I hit this while testing Nav Center:

Issue:
<one sentence>

Steps:
1. <step>
2. <step>
3. <step>

Expected:
<what I thought would happen>

Actual:
<what happened instead>

Impact:
<blocking / annoying / minor>

Environment:
- Nav Center: <version or build>
- macOS: <version>
- Workspace: <sample / local private workspace>
- Codex: <signed in / not signed in / not used>

Diagnostics:
<redacted output from navcenterctl feedback-diagnostics --redact>
```

## Safety Check

Before presenting the draft, confirm it contains no private resume content, account data, exact private file paths, unredacted names or emails, or attachments the user did not approve.
