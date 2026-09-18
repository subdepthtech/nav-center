# Security

Nav Center is a local macOS application for inspecting files already present on the user's machine. It is not intended to be hosted as a public service.

## Supported Versions

Only the latest `main` branch is supported until tagged releases begin.

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/subdepthtech/nav-center/security/advisories/new). This repository has private reporting enabled. Include a minimal synthetic reproduction, affected revision, and impact; omit credentials and private workspace content. Do not open public issues for suspected secrets, private-data exposure, or path traversal findings. There is no promised response-time SLA during beta.

## Boundaries

- Nav Center should read and write only inside the configured workspace.
- Package paths must stay under `applications/<package>/`.
- Generated artifacts, tracker databases, private resumes, and vault mirrors should not be committed.
- The in-app Codex integration is optional and must remain confirmation-gated for edit-capable turns.
- Do not expose Nav Center over a public network interface.

## Development controls

CodeQL default setup covers Swift and GitHub Actions; secret scanning and push protection are enabled. Local/CI Gitleaks, workflow checks, native tests, sanitizers, and optional Sonar reports provide different evidence. None establishes release readiness by itself. See [tooling operations](docs/TOOLING.md) for report scope, credentials, and pending setup gates. Keep scanner exclusions limited to explained boundaries; the ATS snapshot is still included in repository secret scans and separate integrity review.
