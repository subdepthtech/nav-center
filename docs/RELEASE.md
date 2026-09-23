# Release

Nav Center's distribution path produces a native-architecture release build, signs the CLI and app with Developer ID, notarizes and staples the DMG, and verifies signatures, Gatekeeper policy, and the final checksum before allowing artifact upload. A successful offline test is not evidence that a real signing identity or downloaded app passes those gates.

## Offline local packaging

For an unsigned local artifact that must not be distributed:

```sh
NAV_CENTER_VERSION=0.1.0-beta.1 NAV_CENTER_BUILD=1 \
  scripts/package-beta-dmg.sh --local
```

The name ends in `-unsigned.dmg`. This mode never invokes signing or notarization. Both packaging modes use `swift build -c release`; ordinary `scripts/build-and-run.sh build` defaults to debug. Set `NAV_CENTER_DIST_DIR` to an absolute temporary directory for isolated checks. Neither mode stops running app instances. Existing DMG, checksum, or notary-result outputs are refused rather than overwritten.

`scripts/build-and-run.sh` stages `LICENSE` and `THIRD_PARTY_NOTICES.md` into the app bundle at `Contents/Resources`. `scripts/package-beta-dmg.sh` copies both files to the DMG root beside the app and the Applications symlink. `--distribution` refuses to build while `THIRD_PARTY_NOTICES.md` contains `PENDING UPSTREAM CONFIRMATION`. `--local` still builds an unsigned image when that marker is present and prints the unsigned warning. The atsim license was confirmed on 2026-09-22, so the current notices contain no marker.

## Version and architecture

Set `NAV_CENTER_VERSION` to a numeric `major.minor.patch` with an optional prerelease suffix, and `NAV_CENTER_BUILD` to a positive integer. The app embeds the numeric version in `CFBundleShortVersionString`, the build number in `CFBundleVersion`, and the complete prerelease version in `NavCenterVersion`. Use a new build number for a new build.

Packaging builds only the host architecture (`arm64` or `x86_64`) and checks both executables with `lipo`. The DMG name and cask hardware requirement must match. Native compilation does not establish support for an untested OS or architecture.

## Distribution prerequisites

Before using `--distribution`, require a clean source tree with complete Git history and preinstalled Gitleaks, then provide a valid Developer ID Application identity and the App Store Connect notarization credentials. Both current-tree and history scans must pass before compilation. Local signing may use an existing authorized keychain. Set `NAV_CENTER_SIGNING_KEYCHAIN` to select an explicit keychain; the scripts do not change the user's keychain search list.

Required environment variables:

- `NAV_CENTER_VERSION`, `NAV_CENTER_BUILD`
- `DEVELOPER_ID_APPLICATION`, beginning with `Developer ID Application: `
- `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_PRIVATE_KEY`

With those values supplied through an approved secret mechanism:

```sh
scripts/package-beta-dmg.sh --distribution
```

Missing values fail before building. The script signs the nested CLI, enclosing app, and DMG in that order. It requires an `Accepted` notary result, successful stapling and validation, DMG integrity, and Gatekeeper checks. The `.dmg.notary.json` retains the service result. The `.dmg.sha256` is generated after stapling and uses the artifact basename, so it can be checked after download. A failed command must not be treated as a distributable release even if intermediate files remain.

`scripts/notarize-dmg.sh <dmg>` supports finalizing an already signed DMG with the same credential requirements and rewrites its checksum only after successful validation. Do not reuse a checksum computed before stapling.

## GitHub workflow

The manual **Beta Release** workflow requires version and build inputs and uses the `release` environment. Configure that environment's authorized reviewers and secrets before running it. The workflow needs:

- The workflow provisions the exact Gitleaks release and SHA-256 in `scripts/tool-versions.json` before scanning. Both current-tree and complete-history scans must pass. Direct local distribution still requires Gitleaks on PATH.
- `DEVELOPER_ID_CERTIFICATE_BASE64`: base64-encoded Developer ID PKCS12 export.
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`: its password.
- The Developer ID identity and three App Store Connect variables listed above as environment secrets.

The workflow fetches complete history, runs hygiene and regression checks, imports the certificate into a temporary keychain, then builds and verifies the artifact. It also mounts the final DMG read-only and checks the packaged app with `scripts/verify-release-artifact.sh`. Temporary certificate/keychain material is removed even after failure. Checkout credentials are not persisted; the workflow has only `contents: read`, pins action commits, and never creates a GitHub Release or pushes a tap. Upload is conditional on all preceding gates succeeding.

The separate CI workflow runs debug/release builds, XCTest with coverage, address/thread sanitizers, shell syntax, and offline release-script regressions. CI passing alone is not a distribution approval. Current/history secret scans do not replace review for private resume, tracker, screenshot, or workspace data.

The prepared workflow selects macOS 26 and Xcode 26.6, restricts execution to `main`, and retains validated release evidence for 90 days. It records GitHub's dependency-graph SPDX inventory plus [dependency boundaries](DEPENDENCIES.md); this is a source dependency inventory, not an exhaustive binary SBOM. The `release` environment requires a human maintainer's approval. Signing credentials and a real workflow run are still separate setup gates; see [SETUP.md](SETUP.md).

Build-provenance attestation is a follow-on for the first authorized signed candidate. Use GitHub's official artifact-attestation action pinned to a verified commit, scoped `id-token: write` and `attestations: write` on the protected release job, and attest the verified final DMG digest. Verify it after downloading the exact candidate. This setup does not add unused OIDC/write permissions or fabricate an attestation before a signed candidate exists.

## Homebrew cask

After the authorized final DMG is uploaded, use its final checksum, explicit architecture, and accepted notarization evidence:

```sh
scripts/update-homebrew-cask.sh \
  0.1.0-beta.1 \
  "https://github.com/subdepthtech/nav-center/releases/download/v0.1.0-beta.1/NavCenter-0.1.0-beta.1-macos-arm64.dmg" \
  "<final-64-character-sha256>" \
  arm64 \
  /path/to/homebrew-tap/Casks/nav-center.rb \
  /path/to/NavCenter-0.1.0-beta.1-macos-arm64.dmg.notary.json
```

The generator rejects malformed values, unsigned asset names, and mismatched version/architecture URLs. It also refuses, before writing, when the notary JSON is missing, is not JSON, or its `status` is not `Accepted`. An accepted result adds a caveat that the cask is Developer ID signed, notarized by Apple, and stapled. The architecture is declared by `depends_on arch:`; this beta ships arm64 only. It declares the hardware requirement, installs the app and CLI, and removes the workspace directory plus AppKit window-state files only through explicit `brew uninstall --zap`. It only writes the requested cask; run `ruby -c <cask-file>` and, where already available, `brew style <cask-file>` separately. Tap publication and install/upgrade/uninstall validation require separate authorization.

## Beta release runbook (maintainer, explicit authorization per step)

Nothing in this runbook is automated or run by assistants without explicit authorization. An `-unsigned.dmg` is never distributable. Testers install from the GitHub prerelease DMG; the Homebrew tap is the alternative and is updated only after that prerelease exists.

1. Dispatch `beta-release.yml` on main with `version` and `build`, and approve the `release` environment.
2. Download the exact workflow artifact.
3. Run `scripts/verify-release-artifact.sh <dmg> --expect-version <v> --expect-build <n>` on the downloaded bytes.
4. `git tag -s v<version> <source sha from BUILD.txt>`, then push the tag. The source SHA is the first line of `BUILD.txt`.
5. `gh release create v<version> --prerelease --verify-tag` with the DMG, `.sha256`, `.notary.json` and `BUILD.txt`, and notes (support matrix, known limits, how to send `navcenterctl feedback-diagnostics` output).
6. `scripts/update-homebrew-cask.sh <version> <release dmg url> <sha256> arm64 <tap>/Casks/nav-center.rb <dmg>.notary.json`.
7. Open a tap PR.
8. After it merges, run `brew install --cask` on the clean machine. Record that pass in [BETA-VERIFICATION-CHECKLIST.md](BETA-VERIFICATION-CHECKLIST.md).

## Required proof before sharing

```sh
# CI checks the committed range; git diff --check only sees uncommitted work.
git log --format= --check --diff-merges=remerge "$(git merge-base main HEAD)..HEAD"
git diff --check
for script in scripts/*.sh; do bash -n "$script"; done
python3 -B -m unittest discover -s scripts/tests -v
swift test --enable-code-coverage
swift build
swift build -c release
```

The release regressions use synthetic build/signing/notary tools and never submit to Apple. For a launch smoke check, explicitly supply a disposable workspace:

```sh
NAV_CENTER_WORKSPACE_ROOT=/absolute/path/to/disposable-workspace \
  scripts/build-and-run.sh --verify
```

This check proves only that a process remained running briefly. Before release, test the exact downloaded, quarantined artifact on a clean supported Mac: check its checksum and version, Gatekeeper acceptance, offline launch with a valid staple, core workflows, update behavior, and explicit uninstall/zap scope. Repeat for every advertised architecture and the minimum supported macOS. Retain source revision, toolchain, signature, notarization, and test evidence. No such trusted distribution proof is implied by the repository's offline tests.
