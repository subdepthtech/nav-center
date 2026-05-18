#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 dist/NavCenter-<version>-macos-<arch>.dmg" >&2
  exit 2
fi

DMG_PATH="$1"

: "${APP_STORE_CONNECT_KEY_ID:?APP_STORE_CONNECT_KEY_ID is required}"
: "${APP_STORE_CONNECT_ISSUER_ID:?APP_STORE_CONNECT_ISSUER_ID is required}"
: "${APP_STORE_CONNECT_PRIVATE_KEY:?APP_STORE_CONNECT_PRIVATE_KEY is required}"

KEY_FILE="$(mktemp -t nav-center-notary-key.XXXXXX)"
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s' "$APP_STORE_CONNECT_PRIVATE_KEY" >"$KEY_FILE"

xcrun notarytool submit "$DMG_PATH" \
  --key "$KEY_FILE" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"
