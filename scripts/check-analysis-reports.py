#!/usr/bin/env python3
"""Validate and relativize real LLVM/SwiftLint reports before artifact upload."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def prepare(root, reports):
    sources = {p.relative_to(root).as_posix() for p in (root / "Sources").rglob("*.swift")}

    def source_path(raw):
        path = Path(raw)
        path = path if path.is_absolute() else root / path
        try:
            relative = path.resolve().relative_to(root).as_posix()
        except ValueError as exc:
            raise ValueError(f"Report path outside repository: {raw}") from exc
        if relative not in sources:
            raise ValueError(f"Report path is not maintained Swift source: {raw}")
        return relative

    coverage = json.loads((reports / "coverage.json").read_text())
    files = [f for data in coverage["data"] for f in data["files"]]
    covered_paths = {source_path(f["filename"]) for f in files}
    if len(covered_paths) != len(files):
        raise ValueError("Duplicate coverage files")
    for file in files:
        counts = file["summary"]["lines"]
        if not (0 <= counts["covered"] <= counts["count"]):
            raise ValueError("Invalid coverage line counts")
    line_total = sum(f["summary"]["lines"]["count"] for f in files)
    line_covered = sum(f["summary"]["lines"]["covered"] for f in files)
    if not covered_paths or line_total <= 0:
        raise ValueError("Empty coverage is not valid analysis evidence")
    text = (reports / "swift-coverage.txt").read_text()
    headers = re.findall(r"^(.+\.swift):$", text, flags=re.MULTILINE)
    if {source_path(path) for path in headers} != covered_paths:
        raise ValueError("LLVM text and JSON file inventories differ")
    for raw in headers:
        text = text.replace(raw + ":\n", source_path(raw) + ":\n")
    findings = json.loads((reports / "swiftlint.json").read_text())
    if not isinstance(findings, list):
        raise ValueError("SwiftLint report must be a JSON array")
    for finding in findings:
        finding["file"] = source_path(finding["file"])
    # Write only after both report types pass validation; do not manufacture coverage.
    (reports / "swift-coverage.txt").write_text(text)
    (reports / "swiftlint.json").write_text(json.dumps(findings, indent=2) + "\n")
    summary = {
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "maintained_source_files": len(sources),
        "coverage_files": len(covered_paths),
        "files_without_coverage": sorted(sources - covered_paths),
        "executable_lines": line_total,
        "covered_lines": line_covered,
        "swiftlint_findings": len(findings),
        "coverage_files_list": sorted(covered_paths),
        "report_sha256": {name: hashlib.sha256((reports / name).read_bytes()).hexdigest()
                          for name in ("swift-coverage.txt", "swiftlint.json")},
    }
    (reports / "analysis-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", type=Path, nargs="?", default=Path("reports/native"))
    args = parser.parse_args()
    prepare(Path(__file__).resolve().parents[1], args.reports)
