#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <version> <dmg-url> <sha256> <cask-file>" >&2
  exit 2
fi

VERSION="$1"
DMG_URL="$2"
SHA256="$3"
CASK_FILE="$4"

mkdir -p "$(dirname "$CASK_FILE")"
cat >"$CASK_FILE" <<RUBY
cask "nav-center" do
  version "$VERSION"
  sha256 "$SHA256"

  url "$DMG_URL"
  name "Nav Center"
  desc "Local-first macOS dashboard for job-application packages and resume workflows"
  homepage "https://github.com/subdepthtech/nav-center"

  depends_on macos: ">= :ventura"

  app "Nav Center.app"
  binary "#{appdir}/Nav Center.app/Contents/MacOS/navcenterctl"

  zap trash: [
    "~/Library/Application Support/Nav Center",
    "~/Library/Preferences/com.subdepthtech.navcenter.plist",
  ]
end
RUBY

if command -v brew >/dev/null 2>&1; then
  brew style "$CASK_FILE"
fi
echo "$CASK_FILE"
