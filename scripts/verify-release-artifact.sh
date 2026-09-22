#!/usr/bin/env bash
# Read-only distribution checks for one DMG, its sidecars, and the mounted app.
# Signs nothing and submits nothing to Apple.
#
# Usage: verify-release-artifact.sh <dmg> [--expect-version <v>] [--expect-build <n>]

set -uo pipefail

usage() {
  printf 'usage: %s <dmg> [--expect-version <v>] [--expect-build <n>]\n' "$0" >&2
  exit 64
}

if [[ $# -lt 1 ]]; then
  usage
fi

dmg="$1"
shift
expect_version=""
expect_build=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect-version)
      [[ $# -ge 2 && -n "${2:-}" && -z "$expect_version" ]] || usage
      expect_version="$2"
      shift 2
      ;;
    --expect-build)
      [[ $# -ge 2 && -n "${2:-}" && -z "$expect_build" ]] || usage
      expect_build="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

if [[ ! -f "$dmg" ]]; then
  printf 'No such artifact: %s\n' "$dmg" >&2
  exit 66
fi

failures=0
report() {
  local status="$1"
  local check="$2"
  local reason="${3-}"
  case "$status" in
    PASS)
      printf 'PASS %s\n' "$check"
      ;;
    FAIL)
      printf 'FAIL %s: %s\n' "$check" "$reason"
      failures=$((failures + 1))
      ;;
    MISSING)
      printf 'MISSING %s\n' "$check"
      failures=$((failures + 1))
      ;;
  esac
}

base="$(basename "$dmg")"
case "$base" in
  *-unsigned.dmg)
    report FAIL "name contract" "-unsigned.dmg is a local build and must never be published"
    exit 1
    ;;
  *)
    report PASS "name contract"
    ;;
esac

sidecar="$dmg.sha256"
if [[ ! -f "$sidecar" ]]; then
  report MISSING "checksum sidecar"
else
  actual_sum=""
  if ! actual_sum="$(shasum -a 256 "$dmg" | awk 'NR==1 { print $1 }')"; then
    report FAIL "checksum sidecar" "could not calculate artifact checksum"
  elif reason="$(
    python3 - "$sidecar" "$base" "$actual_sum" <<'PY'
import pathlib
import re
import sys

sidecar, base, actual = sys.argv[1:]
text = pathlib.Path(sidecar).read_text()
if text.endswith("\n"):
    text = text[:-1]
# shasum writes "<64 hex><space><space or *><name>" as one record.
if text == "" or "\n" in text or "\r" in text:
    print("not one checksum line")
    raise SystemExit(1)
match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](.+)", text)
if not match:
    print("not a <64 hex> <space or *> <name> record")
    raise SystemExit(1)
digest, name = match.group(1), match.group(2)
last = name.replace("\\", "/").rstrip("/").split("/")[-1]
if last != base:
    print(f"sidecar names {name}")
    raise SystemExit(1)
if digest.lower() != actual.lower():
    print("digest does not match artifact")
    raise SystemExit(1)
raise SystemExit(0)
PY
  )"; then
    report PASS "checksum sidecar"
  else
    report FAIL "checksum sidecar" "${reason:-could not read checksum sidecar}"
  fi
fi

if hdiutil verify "$dmg" >/dev/null 2>&1; then
  report PASS "hdiutil verify"
else
  report FAIL "hdiutil verify" "command failed"
fi

if codesign --verify --strict --verbose=2 "$dmg" >/dev/null 2>&1; then
  report PASS "codesign --verify --strict"
else
  report FAIL "codesign --verify --strict" "command failed"
fi

notary="$dmg.notary.json"
if [[ ! -f "$notary" ]]; then
  report MISSING "notary result"
elif reason="$(
  python3 - "$notary" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError):
    print("not JSON")
    raise SystemExit(1)
status = data.get("status") if isinstance(data, dict) else None
if isinstance(status, str) and status.lower() == "accepted":
    raise SystemExit(0)
print("status is not accepted")
raise SystemExit(1)
PY
)"; then
  report PASS "notary result"
else
  reason="${reason//$'\n'/}"
  report FAIL "notary result" "${reason:-could not read notary result}"
fi

if xcrun stapler validate "$dmg" >/dev/null 2>&1; then
  report PASS "stapler validate"
else
  report FAIL "stapler validate" "command failed"
fi

if spctl -a -vv -t open --context context:primary-signature "$dmg" >/dev/null 2>&1; then
  report PASS "spctl -t open"
else
  report FAIL "spctl -t open" "command failed"
fi

mount_dir=""
cleanup_mount() {
  if [[ -n "$mount_dir" ]]; then
    hdiutil detach "$mount_dir" >/dev/null 2>&1 || true
    rm -rf "$mount_dir"
    mount_dir=""
  fi
}

mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/nav-center-verify.XXXXXX")"
if [[ -z "$mount_dir" || ! -d "$mount_dir" ]]; then
  report FAIL "hdiutil attach" "could not create a mount directory"
  report MISSING "codesign --verify --deep --strict"
  report MISSING "spctl -t execute"
  report MISSING "LICENSE"
  report MISSING "THIRD_PARTY_NOTICES.md"
  if [[ -n "$expect_version" ]]; then
    report MISSING "CFBundleShortVersionString"
    report MISSING "NavCenterVersion"
  fi
  if [[ -n "$expect_build" ]]; then
    report MISSING "CFBundleVersion"
  fi
else
  trap cleanup_mount EXIT
  app="$mount_dir/Nav Center.app"
  plist="$app/Contents/Info.plist"
  if hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$dmg" >/dev/null 2>&1; then
    report PASS "hdiutil attach"
    if codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
      report PASS "codesign --verify --deep --strict"
    else
      report FAIL "codesign --verify --deep --strict" "command failed"
    fi
    if spctl -a -vv -t execute "$app" >/dev/null 2>&1; then
      report PASS "spctl -t execute"
    else
      report FAIL "spctl -t execute" "command failed"
    fi
    if [[ -f "$mount_dir/LICENSE" ]]; then
      report PASS "LICENSE"
    else
      report FAIL "LICENSE" "not found at the mount root"
    fi
    if [[ -f "$mount_dir/THIRD_PARTY_NOTICES.md" ]]; then
      report PASS "THIRD_PARTY_NOTICES.md"
    else
      report FAIL "THIRD_PARTY_NOTICES.md" "not found at the mount root"
    fi
    read_plist_key() {
      local key="$1"
      local value=""
      if ! value="$(/usr/bin/plutil -extract "$key" raw "$plist" 2>/dev/null)"; then
        return 1
      fi
      printf '%s' "${value//$'\n'/}"
    }
    if [[ -n "$expect_version" ]]; then
      expected_short="${expect_version%%-*}"
      if actual="$(read_plist_key CFBundleShortVersionString)"; then
        if [[ "$actual" == "$expected_short" ]]; then
          report PASS "CFBundleShortVersionString"
        else
          report FAIL "CFBundleShortVersionString" "expected ${expected_short}, found ${actual}"
        fi
      else
        report FAIL "CFBundleShortVersionString" "could not read CFBundleShortVersionString"
      fi
      if actual="$(read_plist_key NavCenterVersion)"; then
        if [[ "$actual" == "$expect_version" ]]; then
          report PASS "NavCenterVersion"
        else
          report FAIL "NavCenterVersion" "expected ${expect_version}, found ${actual}"
        fi
      else
        report FAIL "NavCenterVersion" "could not read NavCenterVersion"
      fi
    fi
    if [[ -n "$expect_build" ]]; then
      if actual="$(read_plist_key CFBundleVersion)"; then
        if [[ "$actual" == "$expect_build" ]]; then
          report PASS "CFBundleVersion"
        else
          report FAIL "CFBundleVersion" "expected ${expect_build}, found ${actual}"
        fi
      else
        report FAIL "CFBundleVersion" "could not read CFBundleVersion"
      fi
    fi
  else
    report FAIL "hdiutil attach" "could not mount read-only"
    report MISSING "codesign --verify --deep --strict"
    report MISSING "spctl -t execute"
    report MISSING "LICENSE"
    report MISSING "THIRD_PARTY_NOTICES.md"
    if [[ -n "$expect_version" ]]; then
      report MISSING "CFBundleShortVersionString"
      report MISSING "NavCenterVersion"
    fi
    if [[ -n "$expect_build" ]]; then
      report MISSING "CFBundleVersion"
    fi
  fi
fi

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
exit 0
