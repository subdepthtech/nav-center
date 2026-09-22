#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRATCH="${1:-.build}"
REPORTS="${2:-reports/native}"
BIN="$(swift build --scratch-path "$SCRATCH" --show-bin-path)"
# SwiftPM uses the package bundle on Xcode 26 and the test-target bundle on Xcode 27.
# Limit discovery to those known products; reject a stale, ambiguous scratch path.
TEST_BINARY=""
for TEST_NAME in NavCenterPackageTests NavCenterTests; do
  CANDIDATE="$BIN/$TEST_NAME.xctest/Contents/MacOS/$TEST_NAME"
  if [[ -s "$CANDIDATE" ]]; then
    [[ -z "$TEST_BINARY" ]] || { echo "Multiple Nav Center test binaries; rerun coverage in a clean scratch path." >&2; exit 1; }
    TEST_BINARY="$CANDIDATE"
  fi
done
PROFILE="$BIN/codecov/default.profdata"
[[ -s "$TEST_BINARY" && -s "$PROFILE" ]] || { echo "Run swift test --enable-code-coverage with the same scratch path first." >&2; exit 1; }
mkdir -p "$REPORTS"
SOURCES=()
while IFS= read -r -d '' source; do SOURCES+=("$source"); done < <(find "$PWD/Sources" -name '*.swift' -type f -print0)
[[ ${#SOURCES[@]} -gt 0 ]]
xcrun llvm-cov show "$TEST_BINARY" -instr-profile="$PROFILE" -use-color=false "${SOURCES[@]}" > "$REPORTS/swift-coverage.txt"
xcrun llvm-cov export "$TEST_BINARY" -instr-profile="$PROFILE" "${SOURCES[@]}" > "$REPORTS/coverage.json"
xcrun llvm-cov report "$TEST_BINARY" -instr-profile="$PROFILE" "${SOURCES[@]}" > "$REPORTS/coverage-summary.txt"
