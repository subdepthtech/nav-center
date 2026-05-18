# Release

Nav Center beta releases ship through GitHub Releases and the public Homebrew tap after public hygiene checks, signing, and notarization pass.

## Local Beta DMG

```sh
NAV_CENTER_VERSION=0.1.0-beta scripts/package-beta-dmg.sh
```

Outputs:

```text
dist/NavCenter-0.1.0-beta-macos-<arch>.dmg
dist/NavCenter-0.1.0-beta-macos-<arch>.dmg.sha256
```

Set `DEVELOPER_ID_APPLICATION` to sign the staged app and DMG:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
  NAV_CENTER_VERSION=0.1.0-beta \
  scripts/package-beta-dmg.sh
```

## Notarization

```sh
APP_STORE_CONNECT_KEY_ID=... \
APP_STORE_CONNECT_ISSUER_ID=... \
APP_STORE_CONNECT_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)" \
scripts/notarize-dmg.sh dist/NavCenter-0.1.0-beta-macos-arm64.dmg
```

Notarization is separate from local signing. A Developer ID signed build can still fail Gatekeeper until notarization and stapling pass.

## Homebrew Cask

Generate a cask file after the DMG is uploaded and the final SHA256 is known:

```sh
scripts/update-homebrew-cask.sh \
  0.1.0-beta \
  "https://github.com/subdepthtech/nav-center/releases/download/v0.1.0-beta/NavCenter-0.1.0-beta-macos-arm64.dmg" \
  "<sha256>" \
  /path/to/homebrew-tap/Casks/nav-center.rb
```

The cask installs `Nav Center.app`, exposes `navcenterctl`, and removes App Support/preferences only through explicit `brew uninstall --zap`.

## Verification

Run before sharing a beta artifact:

```sh
swift test
swift build
scripts/build-and-run.sh --verify
bash -n scripts/*.sh
hdiutil verify dist/NavCenter-0.1.0-beta-macos-<arch>.dmg
codesign --verify --deep --strict "dist/dmg/Nav Center/Nav Center.app"
spctl -a -vv -t execute "dist/dmg/Nav Center/Nav Center.app"
```

Run `xcrun stapler validate` after notarization.
