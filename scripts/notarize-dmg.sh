#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 dist/NavCenter-<version>-macos-<arch>.dmg" >&2
  exit 2
fi
DMG_PATH="$1"
[[ -f "$DMG_PATH" && ! -L "$DMG_PATH" ]] || { echo "Expected a regular DMG file." >&2; exit 2; }
: "${APP_STORE_CONNECT_KEY_ID:?APP_STORE_CONNECT_KEY_ID is required}"
: "${APP_STORE_CONNECT_ISSUER_ID:?APP_STORE_CONNECT_ISSUER_ID is required}"
: "${APP_STORE_CONNECT_PRIVATE_KEY:?APP_STORE_CONNECT_PRIVATE_KEY is required}"

KEY_FILE="$(mktemp -t nav-center-notary-key.XXXXXX)"
CHECKSUM_FILE=""
trap 'rm -f "$KEY_FILE"; if [[ -n "$CHECKSUM_FILE" ]]; then rm -f "$CHECKSUM_FILE"; fi' EXIT
chmod 600 "$KEY_FILE"
printf '%s' "$APP_STORE_CONNECT_PRIVATE_KEY" >"$KEY_FILE"
unset APP_STORE_CONNECT_PRIVATE_KEY

codesign --verify --strict "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" \
  --key "$KEY_FILE" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait --timeout 20m --output-format json >"$DMG_PATH.notary.json"
[[ "$(plutil -extract status raw "$DMG_PATH.notary.json")" == Accepted ]] || { echo "Notarization was not accepted; inspect $DMG_PATH.notary.json." >&2; exit 1; }
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
hdiutil verify "$DMG_PATH"
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"

# Stapling changes the image. Publish its checksum only after every gate passes.
DMG_DIR="$(cd "$(dirname "$DMG_PATH")" && pwd)"
DMG_NAME="$(basename "$DMG_PATH")"
CHECKSUM_FILE="$(mktemp "$DMG_DIR/.checksum.XXXXXX")"
(cd "$DMG_DIR" && shasum -a 256 "$DMG_NAME") >"$CHECKSUM_FILE"
mv "$CHECKSUM_FILE" "$DMG_PATH.sha256"
CHECKSUM_FILE=""
