#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -z $1 ]]; then
  echo "Usage: $0 <output-dir>" >&2
  exit 2
fi
out=$1
mkdir -p "$out"

swift build
bin=$(swift build --show-bin-path)
doctor_json=$("$bin/navcenterctl" doctor --json)
declare -a states paths variables
index_for() {
  case $1 in
    atsim) index=0 ;; export-tool) index=1 ;; pandoc) index=2 ;;
    pdftotext) index=3 ;; chrome) index=4 ;; ruby) index=5 ;; codex) index=6 ;;
    *) echo "WARN: skipping unknown doctor tool: $1" >&2; return 1 ;;
  esac
}
while IFS='|' read -r name state variable path; do
  if ! index_for "$name"; then continue; fi
  states[$index]=$state
  variables[$index]=$variable
  paths[$index]=$path
done < <(NAV_DOCTOR_JSON="$doctor_json" python3 -c '
import json, os
report = json.loads(os.environ["NAV_DOCTOR_JSON"])
for tool in report["tools"]:
    print("|".join(str(tool.get(key) or "") for key in
                   ("tool", "state", "environmentVariable", "resolvedPath")))
')

version_file=$(mktemp)
trap 'rm -f "$version_file"' EXIT
for name in atsim pandoc pdftotext chrome ruby codex; do
  index_for "$name"
  version=""
  if [[ ${states[$index]:-missing} == found ]]; then
    override=${variables[$index]:-}
    path=${paths[$index]:-}
    if [[ -n $override && ${!override:-} == /* ]]; then path=${!override}; fi
    if [[ $path == '~/'* ]]; then path="$HOME/${path#\~/}"; fi
    if [[ $path != /* || ! -x $path ]]; then
      path=$(command -v "$name" || true)
    fi
    if [[ $name == chrome && ! -x $path ]]; then
      path=/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome
    fi
    if [[ $path != /* || ! -x $path ]]; then path=""; fi
    paths[$index]=$path
    if [[ -n $path ]]; then
      case $name in
        atsim) if "$path" --help >/dev/null 2>&1; then version=present; fi ;;
        pandoc) version=$("$path" --version 2>&1 | head -1 || true) ;;
        pdftotext) version=$("$path" -v 2>&1 | head -1 || true) ;;
        chrome|ruby|codex) version=$("$path" --version 2>&1 | head -1 || true) ;;
      esac
    fi
  fi
  for redact_path in "${paths[@]}"; do
    if [[ -n $redact_path ]]; then version=${version//$redact_path/<tool path>}; fi
  done
  version=${version//$HOME/\~}
  version=${version//$'\n'/ }
  version="${version%"${version##*[![:space:]]}"}"
  printf '%s\t%s\n' "$name" "$version" >> "$version_file"
done
redaction_paths=$(IFS='|'; echo "${paths[*]}|$bin/navcenterctl")

missing=0
for name in atsim pandoc pdftotext chrome; do
  index_for "$name"
  state=${states[$index]:-missing}
  if [[ $state != found ]]; then
    echo "FAIL: $name is required for the integration lane but is $state (set ${variables[$index]:-override})" >&2
    missing=1
  fi
done

lane_status=(--)
redact_log() {
  NAV_REDACT_PATHS="$redaction_paths" python3 -c '
import os, sys
value = sys.stdin.read()
for path in sorted(filter(None, os.environ["NAV_REDACT_PATHS"].split("|")), key=len, reverse=True):
    value = value.replace(path, "<tool path>")
value = value.replace(os.environ["HOME"], "~")
sys.stdout.write(value)
'
}
run_lane() {
  local name=$1 status
  shift
  set +e
  "$@" 2>&1 | redact_log > "$out/$name.log"
  status=${PIPESTATUS[0]}
  set -e
  lane_status+=("$name:$status")
}
if [[ $missing -eq 0 ]]; then
  run_lane ats env NAV_CENTER_TEST_ATSIM_BIN="${paths[0]}" swift test --filter ATSActionReadinessTests
  run_lane chrome env NAV_CENTER_TEST_REAL_CHROME=1 swift test --filter RendererReadinessTests
  run_lane export env NAV_CENTER_TEST_REAL_EXPORT=1 swift test --filter ExportToolReadinessTests
  run_lane cli-export env NAV_CENTER_TEST_REAL_EXPORT=1 NAVCENTERCTL="$bin/navcenterctl" python3 -B scripts/tests/test_cli.py -v CLITests.test_export_artifacts_real_tools_produce_complete_artifact_set
fi

NAV_DOCTOR_JSON="$doctor_json" NAV_VERSION_FILE="$version_file" NAV_OUT="$out" \
  NAV_REDACT_PATHS="$redaction_paths" \
  NAV_SOURCE_SHA="$(git rev-parse HEAD)" NAV_MACOS_VERSION="$(sw_vers -productVersion)" \
  NAV_MACOS_BUILD="$(sw_vers -buildVersion)" NAV_ARCH="$(uname -m)" \
  python3 - "${lane_status[@]}" <<'PY'
import datetime
import json
import os
from pathlib import Path
import re
import sys

home = os.environ["HOME"]
def redact(value):
    for path in sorted(filter(None, os.environ["NAV_REDACT_PATHS"].split("|")), key=len, reverse=True):
        value = value.replace(path, "<tool path>")
    return value.replace(home, "~")

out = Path(os.environ["NAV_OUT"])
doctor = json.loads(os.environ["NAV_DOCTOR_JSON"])
versions = dict(line.rstrip("\n").split("\t", 1) for line in Path(os.environ["NAV_VERSION_FILE"]).read_text().splitlines())
tools = [{"name": item["tool"], "state": item["state"],
          "version": redact(versions.get(item["tool"], ""))}
         for item in doctor["tools"]]
commands = {
    "ats": "NAV_CENTER_TEST_ATSIM_BIN=<atsim> swift test --filter ATSActionReadinessTests",
    "chrome": "NAV_CENTER_TEST_REAL_CHROME=1 swift test --filter RendererReadinessTests",
    "export": "NAV_CENTER_TEST_REAL_EXPORT=1 swift test --filter ExportToolReadinessTests",
    "cli-export": "NAV_CENTER_TEST_REAL_EXPORT=1 NAVCENTERCTL=<navcenterctl> python3 -B scripts/tests/test_cli.py -v CLITests.test_export_artifacts_real_tools_produce_complete_artifact_set",
}
lanes = []
for item in sys.argv[1:]:
    if item == "--":
        continue
    name, exit_code = item.split(":", 1)
    log = (out / f"{name}.log").read_text()
    if name == "cli-export":
        count = re.findall(r"Ran (\d+) tests?", log)
        executed = int(count[-1]) if count else 0
        skipped = 1 if "skipped" in log.lower() else 0
        failure_match = re.search(r"FAILED \((?:failures|errors)=(\d+)", log)
        failures = int(failure_match.group(1)) if failure_match else (1 if "FAILED" in log else 0)
    else:
        matches = re.findall(r"Executed (\d+) tests?(?:, with (\d+) tests? skipped)?", log)
        executed = int(matches[-1][0]) if matches else 0
        skipped = max((int(value or 0) for _, value in matches), default=0)
        failures_match = re.findall(r"with (\d+) failures?", log)
        failures = max(map(int, failures_match), default=0)
    passed = int(exit_code) == 0 and executed > 0 and skipped == 0 and failures == 0
    lanes.append({"name": name, "command": commands[name], "exit_status": int(exit_code),
                  "executed": executed, "skipped": skipped, "failures": failures,
                  "result": "pass" if passed else "fail"})
requested = ("atsim", "pandoc", "pdftotext", "chrome")
passed = all(next((tool["state"] for tool in tools if tool["name"] == name), "missing") == "found"
             for name in requested) and len(lanes) == 4 and all(lane["result"] == "pass" for lane in lanes)
summary = {"schema": 1, "date": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
           "source_sha": os.environ["NAV_SOURCE_SHA"],
           "macos": {"productVersion": os.environ["NAV_MACOS_VERSION"],
                     "buildVersion": os.environ["NAV_MACOS_BUILD"]},
           "arch": os.environ["NAV_ARCH"], "tools": tools, "lanes": lanes,
           "result": "pass" if passed else "fail"}
json_text = json.dumps(summary, indent=2) + "\n"
lines = ["# Integration acceptance", "", f"Result: **{summary['result']}**", "",
         f"Date (UTC): {summary['date']}", f"Source SHA: {summary['source_sha']}",
         f"macOS: {summary['macos']['productVersion']} ({summary['macos']['buildVersion']})",
         f"Architecture: {summary['arch']}", "", "## Tools", "",
         "| Tool | State | Version |", "| --- | --- | --- |"]
lines += [f"| {tool['name']} | {tool['state']} | {tool['version']} |" for tool in tools]
lines += ["", "## Lanes", "", "| Lane | Command | Exit | Executed | Skipped | Failures | Result |",
          "| --- | --- | ---: | ---: | ---: | ---: | --- |"]
lines += [f"| {lane['name']} | `{lane['command']}` | {lane['exit_status']} | {lane['executed']} | {lane['skipped']} | {lane['failures']} | {lane['result']} |" for lane in lanes]
(out / "integration-acceptance.json").write_text(redact(json_text))
(out / "integration-acceptance.md").write_text(redact("\n".join(lines) + "\n"))
PY

NAV_SUMMARY="$out/integration-acceptance.json" python3 -c 'import json,os,sys; sys.exit(0 if json.load(open(os.environ["NAV_SUMMARY"]))["result"] == "pass" else 1)'
