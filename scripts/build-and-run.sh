#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
BUNDLE_NAME="Nav Center"
EXECUTABLE_NAME="NavCenterApp"
CTL_NAME="navcenterctl"
BUNDLE_ID="com.subdepthtech.navcenter"
MIN_SYSTEM_VERSION="13.0"
ICON_NAME="AppIcon"
ICON_SOURCE="$ROOT_DIR/Resources/$ICON_NAME.png"
APP_BUNDLE="$DIST_DIR/$BUNDLE_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
CTL_BINARY="$APP_MACOS/$CTL_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_FILE="$APP_RESOURCES/$ICON_NAME.icns"
WORKSPACE_ROOT="${NAV_CENTER_WORKSPACE_ROOT:-$ROOT_DIR}"
INCLUDE_WORKSPACE_ENV="${NAV_CENTER_INCLUDE_WORKSPACE_ENV:-0}"

for required_tool in sips iconutil; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    echo "$required_tool is required to build the app icon." >&2
    exit 1
  fi
done

stop_existing() {
  pkill -f "$APP_BINARY" >/dev/null 2>&1 || true
  pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
}

stage_icon() {
  if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "missing app icon source: $ICON_SOURCE" >&2
    exit 1
  fi

  local iconset="$DIST_DIR/$ICON_NAME.iconset"
  rm -rf "$iconset"
  mkdir -p "$iconset" "$APP_RESOURCES"

  sips -z 16 16 "$ICON_SOURCE" --out "$iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SOURCE" --out "$iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE" --out "$iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$iconset/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SOURCE" --out "$iconset/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$iconset" -o "$ICON_FILE"
  rm -rf "$iconset"
}

stage_app() {
  swift build --package-path "$ROOT_DIR" --product "$EXECUTABLE_NAME"
  swift build --package-path "$ROOT_DIR" --product "$CTL_NAME"
  local build_binary
  build_binary="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/$EXECUTABLE_NAME"
  local ctl_build_binary
  ctl_build_binary="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/$CTL_NAME"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$build_binary" "$APP_BINARY"
  cp "$ctl_build_binary" "$CTL_BINARY"
  chmod +x "$APP_BINARY"
  chmod +x "$CTL_BINARY"
  stage_icon

  local env_plist=""
  if [[ "$INCLUDE_WORKSPACE_ENV" == "1" ]]; then
    env_plist="  <key>LSEnvironment</key>
  <dict>
    <key>NAV_CENTER_WORKSPACE_ROOT</key>
    <string>$WORKSPACE_ROOT</string>
  </dict>"
  fi

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$BUNDLE_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$BUNDLE_NAME</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
$env_plist
</dict>
</plist>
PLIST
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

stop_existing
stage_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -f "$APP_BINARY" >/dev/null
    echo "$BUNDLE_NAME launched from $APP_BUNDLE"
    ;;
  build)
    echo "$BUNDLE_NAME built at $APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|build|--debug|--logs|--verify]" >&2
    exit 2
    ;;
esac
