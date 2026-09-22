#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "usage: $0 <version> <https-dmg-url> <sha256> <arm64|x86_64> <cask-file> <notary-json>" >&2
  exit 2
fi
VERSION="$1"
DMG_URL="$2"
SHA256="$3"
ARCH="$4"
CASK_FILE="$5"
NOTARY_JSON="$6"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$ ]] || { echo "Invalid version." >&2; exit 2; }
[[ "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "Expected a SHA256 digest." >&2; exit 2; }
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { echo "Unsupported architecture." >&2; exit 2; }
# Restrict generated Ruby to a plain HTTPS URL and the exact versioned artifact.
[[ "$DMG_URL" =~ ^https://[A-Za-z0-9._~:/%+@=-]+$ && "$DMG_URL" == */NavCenter-"$VERSION"-macos-"$ARCH".dmg ]] || { echo "URL must match the version and architecture of a distribution DMG." >&2; exit 2; }
if [[ ! -f "$NOTARY_JSON" ]]; then
  echo "notary evidence not found: $NOTARY_JSON" >&2
  exit 2
fi
python3 - "$NOTARY_JSON" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError):
    print(f"notary evidence is not JSON: {path}", file=sys.stderr)
    raise SystemExit(2)
status = data.get("status") if isinstance(data, dict) else None
if not isinstance(status, str) or status.lower() != "accepted":
    print(f"notary evidence status is not Accepted: {path}", file=sys.stderr)
    raise SystemExit(2)
PY

mkdir -p "$(dirname "$CASK_FILE")"
cat >"$CASK_FILE" <<RUBY
cask "nav-center" do
  version "$VERSION"
  sha256 "$SHA256"

  url "$DMG_URL"
  name "Nav Center"
  desc "Local-first macOS dashboard for job-application packages and resume workflows"
  homepage "https://github.com/subdepthtech/nav-center"

  depends_on arch: :$ARCH
  depends_on macos: ">= :ventura"

  app "Nav Center.app"
  binary "#{appdir}/Nav Center.app/Contents/MacOS/navcenterctl"

  caveats "Nav Center #{version} is Developer ID signed, notarized by Apple, and stapled. Beta: arm64 only."

  zap trash: [
    "~/Library/Application Support/Nav Center",
    "~/Library/Preferences/com.subdepthtech.navcenter.plist",
    "~/Library/Saved Application State/com.subdepthtech.navcenter.savedState",
  ]
end
RUBY

echo "$CASK_FILE"
