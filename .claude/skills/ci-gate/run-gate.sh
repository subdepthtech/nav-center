#!/bin/bash
# Local equivalent of the CI gate defined in .github/workflows/ci.yml, following
# the command sequence in docs/TESTING.md. Runs every gate even after a failure
# so one run reports the full picture, and keeps all build products and logs in
# one disposable directory.
#
# Usage: run-gate.sh [--full]
#   default  repository checks, coverage build/test, release build, CLI suite
#   --full   adds the release-configuration CLI run, address and thread
#            sanitizers, and coverage/SwiftLint report export

set -uo pipefail

full=0
for arg in "$@"; do
  case "$arg" in
    --full) full=1 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 64 ;;
  esac
done

repo_root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$repo_root" || exit 1

if ! run_root="$(mktemp -d "${TMPDIR:-/tmp}/nav-center-ci-gate.XXXXXX")" || [ -z "$run_root" ]; then
  printf 'Unable to create the temporary run directory.\n' >&2
  exit 1
fi
log_dir="$run_root/logs"
report_dir="$run_root/reports/native"
mkdir -p "$log_dir" "$report_dir"

export NAV_CENTER_WORKSPACE_ROOT="$run_root/workspace"
export NAV_CENTER_DIST_DIR="$run_root/dist"
export NAV_CENTER_SKIP_VAULT_SYNC=1
# Coverage-instrumented binaries otherwise drop default.profraw into the repo root.
mkdir -p "$run_root/profraw"
export LLVM_PROFILE_FILE="$run_root/profraw/%p.profraw"

pinned_xcode=/Applications/Xcode_26.3.app/Contents/Developer
if [ -d "$pinned_xcode" ]; then
  export DEVELOPER_DIR="$pinned_xcode"
fi

statuses=()
failures=0

record() {
  statuses+=("$1|$2")
  case "$1" in
    FAIL|BLOCKED) failures=$((failures + 1)) ;;
  esac
}

# gate <name> <logfile> <command...>
gate() {
  local name="$1" log="$2"
  shift 2
  printf '\n=== %s ===\n' "$name"
  if "$@" >"$log" 2>&1; then
    record PASS "$name"
    printf 'PASS  %s\n' "$name"
    return 0
  fi
  if grep -qiE 'license|first launch|xcode-select|xcodebuild: error: tool|SourceKit' "$log"; then
    record BLOCKED "$name"
    printf 'BLOCKED  %s  (toolchain prerequisite, not a source failure)\n' "$name"
  else
    record FAIL "$name"
    printf 'FAIL  %s\n' "$name"
  fi
  tail -20 "$log"
  return 1
}

committed_range_check() {
  local ref base
  for ref in origin/main main; do
    if base="$(git merge-base "$ref" HEAD 2>/dev/null)" && [ -n "$base" ] && [ "$base" != "$(git rev-parse HEAD)" ]; then
      git log --format= --check --diff-merges=remerge "$base..HEAD"
      return $?
    fi
  done
  # On main itself, or with no base branch available, check the tip commit only.
  git log -1 --format= --check --diff-merges=remerge HEAD
}

script_syntax_check() {
  local script
  for script in scripts/*.sh; do
    bash -n "$script" || return 1
  done
}

swiftlint_report() {
  local lint_status=0
  swiftlint lint --strict --no-cache --config .swiftlint.yml --reporter json \
    >"$report_dir/swiftlint.json" || lint_status=$?
  # SwiftLint returns 2 for strict lint findings, which remain advisory here.
  # Other failures must not be reported as successfully generated evidence.
  if [ "$lint_status" -ne 0 ] && [ "$lint_status" -ne 2 ]; then
    printf 'SwiftLint failed with exit status %s.\n' "$lint_status" >&2
    return 1
  fi
  python3 - "$report_dir/swiftlint.json" "$lint_status" <<'PY'
import json
from pathlib import Path
import sys

findings = json.loads(Path(sys.argv[1]).read_text())
if not isinstance(findings, list) or any(
    not isinstance(finding, dict)
    or any(not isinstance(finding.get(key), str) or not finding[key]
           for key in ("file", "rule_id", "reason"))
    or finding.get("severity") not in ("Warning", "Error")
    for finding in findings
):
    raise ValueError("SwiftLint report must be an array of valid findings")
if sys.argv[2] == "2" and not findings:
    raise ValueError("SwiftLint failed without reporting lint findings")
print(f"SwiftLint report generated: {len(findings)} advisory finding(s).")
PY
}

printf 'Run directory: %s\n' "$run_root"
{
  printf 'revision: %s\n' "$(git rev-parse HEAD)"
  printf 'dirty:\n'
  git status --short
  printf 'DEVELOPER_DIR: %s\n' "${DEVELOPER_DIR:-<unset, using xcode-select default>}"
  xcodebuild -version 2>&1
  xcrun swift --version 2>&1
} >"$report_dir/toolchain.txt" 2>&1
printf 'Recorded revision and toolchain in %s\n' "$report_dir/toolchain.txt"

gate "committed whitespace and conflict markers" "$log_dir/whitespace.log" committed_range_check
gate "release script syntax" "$log_dir/script-syntax.log" script_syntax_check
gate "release and tooling suites" "$log_dir/scripts-tests.log" \
  python3 -B -m unittest discover -s scripts/tests -v
gate "vendor snapshot integrity" "$log_dir/verify-vendor.log" \
  python3 -B scripts/verify-vendor.py

build_root="$run_root/build"
release_root="$run_root/release"

gate "swift build (coverage)" "$log_dir/build.log" \
  xcrun swift build --scratch-path "$build_root" --enable-code-coverage
gate "swift test (coverage)" "$log_dir/swift-test.log" \
  xcrun swift test --scratch-path "$build_root" --enable-code-coverage
gate "swift build -c release" "$log_dir/build-release.log" \
  xcrun swift build --scratch-path "$release_root" -c release

debug_bin="$(xcrun swift build --scratch-path "$build_root" --show-bin-path 2>/dev/null)"
if [ -x "$debug_bin/navcenterctl" ]; then
  NAVCENTERCTL="$debug_bin/navcenterctl" \
    gate "navcenterctl behavior (debug)" "$log_dir/cli-debug.log" \
    python3 -B scripts/tests/test_cli.py -v
else
  record BLOCKED "navcenterctl behavior (debug)"
  printf 'BLOCKED  navcenterctl behavior (debug)  (executable not built)\n'
fi

if [ "$full" -eq 1 ]; then
  release_bin="$(xcrun swift build --scratch-path "$release_root" -c release --show-bin-path 2>/dev/null)"
  if [ -x "$release_bin/navcenterctl" ]; then
    NAVCENTERCTL="$release_bin/navcenterctl" \
      gate "navcenterctl behavior (release)" "$log_dir/cli-release.log" \
      python3 -B scripts/tests/test_cli.py -v
  else
    record BLOCKED "navcenterctl behavior (release)"
    printf 'BLOCKED  navcenterctl behavior (release)  (executable not built)\n'
  fi

  gate "address sanitizer build" "$log_dir/asan-build.log" \
    xcrun swift build --scratch-path "$run_root/asan" --sanitize=address
  gate "address sanitizer tests" "$log_dir/asan.log" \
    xcrun swift test --scratch-path "$run_root/asan" --sanitize=address
  gate "thread sanitizer build" "$log_dir/tsan-build.log" \
    xcrun swift build --scratch-path "$run_root/tsan" --sanitize=thread
  gate "thread sanitizer tests" "$log_dir/tsan.log" \
    xcrun swift test --scratch-path "$run_root/tsan" --sanitize=thread

  gate "coverage export" "$log_dir/coverage.log" \
    bash scripts/export-coverage.sh "$build_root" "$report_dir"
  if command -v swiftlint >/dev/null 2>&1; then
    gate "swiftlint report generated" "$log_dir/swiftlint.log" swiftlint_report
  else
    record BLOCKED "swiftlint report generated"
    printf 'BLOCKED  swiftlint report  (install via scripts/bootstrap-tools.py --tool swiftlint)\n'
  fi
  gate "analysis report validation" "$log_dir/check-reports.log" \
    python3 -B scripts/check-analysis-reports.py "$report_dir"
fi

printf '\n===== CI gate summary =====\n'
for entry in "${statuses[@]}"; do
  printf '%-8s %s\n' "${entry%%|*}" "${entry#*|}"
done
printf '\nLogs and evidence: %s\n' "$run_root"
printf 'Revision: %s\n' "$(git rev-parse HEAD)"
if [ "$full" -eq 0 ]; then
  printf 'Not run in this mode: release-configuration CLI suite, sanitizers, coverage export. Use --full.\n'
fi
printf 'Never covered locally: signed/notarized distribution, UI and VoiceOver, minimum-macOS, real Chrome and installed-ATS integrations.\n'

if [ "$failures" -gt 0 ]; then
  printf '\n%d gate(s) did not pass.\n' "$failures"
  exit 1
fi
printf '\nAll gates passed.\n'
