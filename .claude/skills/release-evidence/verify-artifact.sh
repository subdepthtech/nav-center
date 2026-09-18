#!/bin/bash
# Check one packaged DMG against the distribution gates in docs/RELEASE.md and
# docs/PUBLIC_RELEASE_CHECKLIST.md. Read-only: it inspects the artifact and its
# sidecars, signs nothing, and submits nothing to Apple.
#
# Usage: verify-artifact.sh /path/to/NavCenter-<version>-macos-<arch>.dmg

set -uo pipefail

dmg="${1:-}"
if [ -z "$dmg" ]; then
  printf 'Usage: %s /path/to/artifact.dmg\n' "$0" >&2
  exit 64
fi
if [ ! -f "$dmg" ]; then
  printf 'No such artifact: %s\n' "$dmg" >&2
  exit 66
fi

base="$(basename "$dmg")"
failures=0

report() {
  printf '%-8s %s\n' "$1" "$2"
  case "$1" in
    FAIL|MISSING) failures=$((failures + 1)) ;;
  esac
}

printf 'Artifact: %s\n\n' "$dmg"

# Gate 1: unsigned local builds are never distributable, whatever else passes.
case "$base" in
  *-unsigned.dmg)
    report FAIL "name contract: -unsigned.dmg is a local build and must never be published"
    printf '\nStopping: an unsigned local artifact cannot satisfy any distribution gate.\n'
    exit 1
    ;;
  *)
    report PASS "name contract: not an -unsigned.dmg output"
    ;;
esac

# Gate 2: checksum, and agreement with the required published sidecar.
if actual_sum="$(shasum -a 256 "$dmg" | awk '{print $1}')"; then
  printf '%-8s %s\n' "INFO" "sha256 $actual_sum"
else
  report FAIL "could not calculate artifact checksum"
fi
if [ -f "$dmg.sha256" ]; then
  # Do not let a sidecar select a different file through `shasum -c`.
  # Packaging emits one SHA-256 record naming this exact artifact basename.
  if python3 - "$dmg.sha256" "$base" "$actual_sum" <<'PY' 2>/dev/null
import pathlib
import re
import sys

sidecar, basename, actual = sys.argv[1:]
record = re.fullmatch(r"([0-9a-fA-F]{64}) [ *]([^\r\n]+)\n?", pathlib.Path(sidecar).read_text())
sys.exit(0 if record and record[2] == basename and record[1].lower() == actual else 1)
PY
  then
    report PASS "checksum sidecar matches artifact"
  else
    report FAIL "checksum sidecar does not match artifact"
  fi
else
  report MISSING "checksum sidecar $base.sha256 not found"
fi

# Gate 3: image integrity.
if hdiutil verify "$dmg" >/dev/null 2>&1; then
  report PASS "hdiutil verify"
else
  report FAIL "hdiutil verify"
fi

# Gate 4: signature over the DMG itself.
if codesign --verify --strict --verbose=2 "$dmg" >/dev/null 2>&1; then
  report PASS "codesign --verify --strict"
else
  report FAIL "codesign --verify --strict"
fi

# Gate 5: retained notary result must say Accepted.
notary="$dmg.notary.json"
if [ -f "$notary" ]; then
  if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if str(d.get('status','')).lower()=='accepted' else 1)" "$notary" 2>/dev/null; then
    report PASS "notary result Accepted ($(basename "$notary"))"
  else
    report FAIL "notary result present but not Accepted"
  fi
else
  report MISSING "notary result $(basename "$notary") not found"
fi

# Gate 6: staple and Gatekeeper acceptance.
if xcrun stapler validate "$dmg" >/dev/null 2>&1; then
  report PASS "stapler validate"
else
  report FAIL "stapler validate"
fi

if spctl -a -t open --context context:primary-signature "$dmg" >/dev/null 2>&1; then
  report PASS "spctl Gatekeeper assessment"
else
  report FAIL "spctl Gatekeeper assessment"
fi

cat <<'NOTE'

Not established by this script, and required before publishing (docs/RELEASE.md,
docs/PUBLIC_RELEASE_CHECKLIST.md):
  - nested app and embedded CLI signature verification, and app execute assessment
  - the exact downloaded, quarantined artifact checked on a clean supported Mac
  - offline launch with a valid staple, and app version/build confirmation
  - core workflows, update behavior, and explicit uninstall/zap scope
  - every advertised architecture and the minimum supported macOS
  - secret and private-data scans over the current tree and git history
NOTE

if [ "$failures" -gt 0 ]; then
  printf '\n%d distribution gate(s) failed. Not distributable.\n' "$failures"
  exit 1
fi
printf '\nDMG-only checks passed. Nested-code verification and clean-machine evidence remain outstanding; distribution readiness is not established.\n'
