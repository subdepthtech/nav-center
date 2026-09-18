#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---distribution}"
[[ $# -le 1 && ( "$MODE" == --distribution || "$MODE" == --local ) ]] || { echo "usage: $0 [--distribution|--local]" >&2; exit 2; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$MODE" == --distribution ]]; then
  : "${NAV_CENTER_VERSION:?NAV_CENTER_VERSION is required for distribution}"
  : "${NAV_CENTER_BUILD:?NAV_CENTER_BUILD is required for distribution}"
  : "${DEVELOPER_ID_APPLICATION:?A Developer ID Application signing identity is required}"
  : "${APP_STORE_CONNECT_KEY_ID:?APP_STORE_CONNECT_KEY_ID is required}"
  : "${APP_STORE_CONNECT_ISSUER_ID:?APP_STORE_CONNECT_ISSUER_ID is required}"
  : "${APP_STORE_CONNECT_PRIVATE_KEY:?APP_STORE_CONNECT_PRIVATE_KEY is required}"
  [[ "$DEVELOPER_ID_APPLICATION" == 'Developer ID Application: '* ]] || { echo "Distribution requires a Developer ID Application identity." >&2; exit 2; }
  command -v gitleaks >/dev/null || { echo "Distribution requires preinstalled Gitleaks." >&2; exit 1; }
  SHALLOW="$(git -C "$ROOT_DIR" rev-parse --is-shallow-repository)"
  [[ "$SHALLOW" == false ]] || { echo "Distribution requires complete Git history." >&2; exit 1; }
  SOURCE_STATUS="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)"
  [[ -z "$SOURCE_STATUS" ]] || { echo "Distribution requires a clean source tree." >&2; exit 1; }
  gitleaks dir "$ROOT_DIR" --redact
  gitleaks git "$ROOT_DIR" --log-opts="--all" --redact
fi
VERSION="${NAV_CENTER_VERSION:-0.1.0-beta}"
BUILD_NUMBER="${NAV_CENTER_BUILD:-1}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$ ]] || { echo "Invalid NAV_CENTER_VERSION." >&2; exit 2; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "NAV_CENTER_BUILD must be a positive integer." >&2; exit 2; }
ARCH="$(uname -m)"
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { echo "Unsupported build architecture: $ARCH" >&2; exit 2; }
DIST_DIR="${NAV_CENTER_DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$DIST_DIR/Nav Center.app"
SUFFIX=""
if [[ "$MODE" == --local ]]; then SUFFIX="-unsigned"; fi
DMG_NAME="NavCenter-${VERSION}-macos-${ARCH}${SUFFIX}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
for output in "$DMG_PATH" "$DMG_PATH.sha256" "$DMG_PATH.notary.json"; do
  [[ ! -e "$output" && ! -L "$output" ]] || { echo "Refusing to overwrite release output: $output" >&2; exit 1; }
done

NAV_CENTER_VERSION="$VERSION" NAV_CENTER_BUILD="$BUILD_NUMBER" NAV_CENTER_BUILD_CONFIGURATION=release \
  NAV_CENTER_INCLUDE_WORKSPACE_ENV=0 "$ROOT_DIR/scripts/build-and-run.sh" build

STAGING_DIR="$(mktemp -d "$DIST_DIR/.dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
STAGED_APP="$STAGING_DIR/Nav Center.app"
for binary in NavCenterApp navcenterctl; do
  [[ "$(lipo -archs "$STAGED_APP/Contents/MacOS/$binary")" == "$ARCH" ]] || { echo "Unexpected binary architecture: $binary" >&2; exit 1; }
done

if [[ "$MODE" == --distribution ]]; then
  keychain_args=()
  if [[ -n "${NAV_CENTER_SIGNING_KEYCHAIN:-}" ]]; then keychain_args=(--keychain "$NAV_CENTER_SIGNING_KEYCHAIN"); fi
  # Sign nested executable first, then its enclosing app, then the container.
  codesign --force --options runtime --timestamp ${keychain_args[@]+"${keychain_args[@]}"} --sign "$DEVELOPER_ID_APPLICATION" "$STAGED_APP/Contents/MacOS/navcenterctl"
  codesign --force --options runtime --timestamp ${keychain_args[@]+"${keychain_args[@]}"} --sign "$DEVELOPER_ID_APPLICATION" "$STAGED_APP"
  codesign --verify --deep --strict "$STAGED_APP"
fi

hdiutil create -volname "Nav Center ${VERSION}" -srcfolder "$STAGING_DIR" -format UDZO "$DMG_PATH" >/dev/null
hdiutil verify "$DMG_PATH"
if [[ "$MODE" == --distribution ]]; then
  codesign --force --timestamp ${keychain_args[@]+"${keychain_args[@]}"} --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
  "$ROOT_DIR/scripts/notarize-dmg.sh" "$DMG_PATH"
  spctl -a -vv -t execute "$STAGED_APP"
else
  (cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" >"$DMG_NAME.sha256")
  echo "Unsigned local test artifact; not eligible for distribution." >&2
fi
(cd "$DIST_DIR" && shasum -a 256 -c "$DMG_NAME.sha256")
echo "$DMG_PATH"
echo "$DMG_PATH.sha256"
