# Dependency and license inventory

This inventory describes source dependencies, not a complete binary SBOM. Review it when a dependency or distribution boundary changes.

| Component | Current boundary | License / update responsibility |
| --- | --- | --- |
| Nav Center source | Core library, SwiftUI executable, CLI; Swift tools 5.9, macOS 26 minimum | Repository MIT license |
| SwiftPM packages | No declared third-party dependencies or Package.resolved | Add SwiftPM Dependabot when dependencies exist; review transitive licenses |
| Apple frameworks and toolchain | Foundation, Darwin, CryptoKit, SQLite3, SwiftUI, AppKit, PDFKit, UniformTypeIdentifiers, CoreFoundation | System/SDK dependencies; Apple agreement remains user-owned |
| Ruby, Pandoc, Chrome, Poppler | Optional/native runtime helpers, discovered on the user's machine | Not bundled by this tooling change; validate versions and licenses before bundling |
| Codex app-server | Optional independently installed/signed-in tool | Not bundled; no access to auth storage for tests |
| External atsim | Existing optional executable integration | Copied source does not activate it |
| `vendor/atsim` | Unchanged review snapshot at `cc37c5b1e3a4f7dfe17d9f043eb18021ff6faef4`; 11 upstream file hashes; not built, bundled, or shipped | See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). `PENDING UPSTREAM CONFIRMATION` is a distribution gate: `--distribution` refuses to build while that marker remains |
| Snapshot JS helper | `@opencode-ai/sdk` in the copied package/lock; not installed or integrated | Review lock and transitive licenses/security explicitly with a snapshot update |
| Development binaries | Gitleaks, actionlint, zizmor, SwiftLint from official pinned releases | Versions and archive SHA-256 in `scripts/tool-versions.json`; not shipped in the app |
| GitHub Actions | Full SHA references in `.github/workflows` | Weekly Dependabot PRs; human review of changes and permissions |
| SonarQube Cloud | Optional source/analysis service, maintained Swift only | OSS onboarding and account permissions must be verified; not a package dependency |

`python3 -B scripts/verify-vendor.py` checks both hashes and the exact snapshot file inventory, and requires [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) to name `vendor/atsim` and the snapshot commit from `vendor/atsim/UPSTREAM.md`. While that notice contains `PENDING UPSTREAM CONFIRMATION`, the command reports the open distribution gate and still exits successfully. A matching manifest is integrity evidence, not upstream security or license approval. Never let dependency bots rewrite the snapshot implicitly.

The prepared protected release workflow exports GitHub's SPDX dependency graph through [`scripts/export-sbom.py`](../scripts/export-sbom.py) and includes this file with the final candidate. The asynchronous GitHub API reports the repository graph at generation time, not an inventory guaranteed to match the release SHA. Its metadata records retrieval time, package count, scope and digest. GitHub may omit copied sources, system frameworks, and dynamically discovered tools; those limitations must remain visible. Retain the manifest, lockfiles, source revision, toolchain, final DMG checksum, signing/notarization evidence, and later provenance with an authorized release. [GitHub's current SBOM API](https://docs.github.com/en/rest/dependency-graph/sboms).
