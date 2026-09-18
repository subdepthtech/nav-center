#!/usr/bin/env python3
"""Export GitHub's current repository graph, not a revision-bound binary SBOM."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time


def api(endpoint):
    # gh follows GitHub's download redirect without exposing a token in arguments.
    result = subprocess.run([
        "gh", "api", "--method", "GET", "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: 2026-03-10", "--include", endpoint,
    ], text=True, timeout=30, capture_output=True)
    headers, separator, body = result.stdout.partition("\r\n\r\n")
    if not separator:
        headers, separator, body = result.stdout.partition("\n\n")
    status_match = re.match(r"HTTP/\S+\s+(\d{3})(?:\s|$)", headers)
    if not separator or not status_match:
        detail = result.stderr.strip() or "response status was unavailable"
        raise SystemExit(f"GitHub API request failed for {endpoint}: {detail}")
    status = int(status_match.group(1))
    if not 200 <= status < 300:
        raise SystemExit(f"GitHub API request failed with HTTP {status} for {endpoint}")
    if result.returncode:
        detail = result.stderr.strip() or f"gh exited with status {result.returncode}"
        raise SystemExit(f"GitHub API request failed for {endpoint}: {detail}")
    return status, body


def parse_json(raw, context):
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise SystemExit(f"GitHub returned invalid JSON {context}: {error.msg}") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists() or args.output.with_suffix(".metadata.json").exists():
        raise SystemExit("Refusing to overwrite existing inventory evidence")
    repo = "subdepthtech/nav-center"
    prefix = f"https://api.github.com/repos/{repo}/dependency-graph/sbom/fetch-report/"
    _, raw_request = api(f"repos/{repo}/dependency-graph/sbom/generate-report")
    request = parse_json(raw_request, "while starting the SBOM report")
    report_url = request["sbom_url"]
    if not re.fullmatch(re.escape(prefix) + r"[0-9a-fA-F-]+", report_url):
        raise SystemExit("Unexpected SBOM report location")
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        status, raw = api(report_url)
        if status == 202 or not raw.strip():
            # These are the only signals that the requested report is still generating.
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(3, remaining))
            continue

        sbom = parse_json(raw, "while fetching the SBOM report")
        if not isinstance(sbom, dict):
            raise SystemExit("GitHub returned an SBOM payload that is not a JSON object")
        if "spdxVersion" not in sbom:
            raise SystemExit("GitHub returned an SBOM report missing spdxVersion; expected an SPDX document")
        if (not isinstance(sbom["spdxVersion"], str)
                or not sbom["spdxVersion"].startswith("SPDX-")
                or not isinstance(sbom.get("packages"), list)):
            raise SystemExit("GitHub returned an SBOM report with an invalid SPDX schema")
        data = json.dumps(sbom, indent=2) + "\n"
        args.output.parent.mkdir(parents=True, exist_ok=True)
        output_created = False
        metadata_created = False
        try:
            with args.output.open("x") as stream:
                output_created = True
                stream.write(data)
            metadata = {
                "repository": repo,
                "retrieved_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "scope": "GitHub repository dependency graph at generation time; not guaranteed to match the release SHA or all binary/runtime dependencies",
                "sha256": hashlib.sha256(data.encode()).hexdigest(),
                "packages": len(sbom["packages"]),
            }
            with args.output.with_suffix(".metadata.json").open("x") as stream:
                metadata_created = True
                json.dump(metadata, stream, indent=2)
                stream.write("\n")
            print(f"Exported repository-graph SPDX inventory: {len(sbom['packages'])} packages")
        except BaseException:
            if metadata_created:
                args.output.with_suffix(".metadata.json").unlink(missing_ok=True)
            if output_created:
                args.output.unlink(missing_ok=True)
            raise
        return
    raise SystemExit("GitHub SBOM was not ready within 60 seconds; retry the inventory step later")


if __name__ == "__main__":
    main()
