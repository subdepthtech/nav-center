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
    return subprocess.check_output([
        "gh", "api", "--method", "GET", "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: 2026-03-10", endpoint,
    ], text=True, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists() or args.output.with_suffix(".metadata.json").exists():
        raise SystemExit("Refusing to overwrite existing inventory evidence")
    repo = "subdepthtech/nav-center"
    prefix = f"https://api.github.com/repos/{repo}/dependency-graph/sbom/fetch-report/"
    request = json.loads(api(f"repos/{repo}/dependency-graph/sbom/generate-report"))
    report_url = request["sbom_url"]
    if not re.fullmatch(re.escape(prefix) + r"[0-9a-fA-F-]+", report_url):
        raise SystemExit("Unexpected SBOM report location")
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        raw = api(report_url)
        if raw.strip():
            sbom = json.loads(raw)
            if not sbom.get("spdxVersion", "").startswith("SPDX-") or not isinstance(sbom.get("packages"), list):
                raise SystemExit("GitHub did not return an SPDX package inventory")
            data = json.dumps(sbom, indent=2) + "\n"
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with args.output.open("x") as stream:
                stream.write(data)
            metadata = {
                "repository": repo,
                "retrieved_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "scope": "GitHub repository dependency graph at generation time; not guaranteed to match the release SHA or all binary/runtime dependencies",
                "sha256": hashlib.sha256(data.encode()).hexdigest(),
                "packages": len(sbom["packages"]),
            }
            with args.output.with_suffix(".metadata.json").open("x") as stream:
                json.dump(metadata, stream, indent=2)
                stream.write("\n")
            print(f"Exported repository-graph SPDX inventory: {len(sbom['packages'])} packages")
            return
        # HTTP 202 has no body. Fail rather than silently using an old inventory.
        time.sleep(3)
    raise SystemExit("GitHub SBOM was not ready within 60 seconds; retry the inventory step later")


if __name__ == "__main__":
    main()
