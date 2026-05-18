#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${NAV_CENTER_VERSION:-0.1.0-beta}"
ARCH="$(uname -m)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Nav Center.app"
STAGING_DIR="$DIST_DIR/dmg/Nav Center"
DMG_NAME="NavCenter-${VERSION}-macos-${ARCH}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

NAV_CENTER_INCLUDE_WORKSPACE_ENV=0 "$ROOT_DIR/scripts/build-and-run.sh" build

rm -rf "$STAGING_DIR" "$DMG_PATH" "$DMG_PATH.sha256"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$STAGING_DIR/Nav Center.app"
else
  codesign --force --deep --options runtime --sign - "$STAGING_DIR/Nav Center.app"
fi

hdiutil create \
  -volname "Nav Center ${VERSION}" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
fi

hdiutil verify "$DMG_PATH"
shasum -a 256 "$DMG_PATH" >"$DMG_PATH.sha256"
echo "$DMG_PATH"
echo "$DMG_PATH.sha256"
