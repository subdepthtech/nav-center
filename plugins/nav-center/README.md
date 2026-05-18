# Nav Center Skills Plugin

This directory is the public marketplace plugin package for Nav Center beta support skills.

## Skills

- `nav-center-codex-setup`: first-run setup, workspace preparation, document intake, master resume review, Codex connection checks, and paused automation setup.
- `nav-center-beta-feedback`: redacted beta feedback and diagnostic report drafting.

## Development

From the repository root, validate the package with:

```sh
plugin-eval analyze plugins/nav-center --format markdown
swift test --filter PluginManifestTests
```
