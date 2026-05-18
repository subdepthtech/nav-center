# Security

Nav Center is a local macOS application for inspecting files already present on the user's machine. It is not intended to be hosted as a public service.

## Supported Versions

Only the latest `main` branch is supported until tagged releases begin.

## Reporting

Please report security issues privately to the maintainer. Do not open public issues for suspected secrets, private-data exposure, or path traversal findings.

## Boundaries

- Nav Center should read and write only inside the configured workspace.
- Package paths must stay under `applications/<package>/`.
- Generated artifacts, tracker databases, private resumes, and vault mirrors should not be committed.
- The in-app Codex integration is optional and must remain confirmation-gated for edit-capable turns.
- Do not expose Nav Center over a public network interface.
