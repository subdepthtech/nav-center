#!/usr/bin/env python3
"""Check the reviewed ATS snapshot without installing or executing it."""
import hashlib
import json
import re
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
root = repo / "vendor/atsim"
manifest = json.loads((root / "UPSTREAM-SHA256.json").read_text())
for relative, expected in manifest.items():
    path = root / relative
    if not path.resolve().is_relative_to(root.resolve()) or path.is_symlink():
        raise SystemExit(f"Unsafe snapshot path: {relative}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Snapshot changed: {relative}")
actual = {str(path.relative_to(root)) for path in root.rglob("*") if path.is_file()}
allowed = set(manifest) | {"UPSTREAM.md", "UPSTREAM-SHA256.json"}
if actual != allowed:
    raise SystemExit(f"Snapshot file inventory changed: {sorted(actual ^ allowed)}")
notices_path = repo / "THIRD_PARTY_NOTICES.md"
if not notices_path.is_file():
    raise SystemExit("Missing THIRD_PARTY_NOTICES.md")
notices = notices_path.read_text()
upstream = (root / "UPSTREAM.md").read_text()
commit_match = re.search(r"(?m)^- Commit: `([0-9a-f]{40})`", upstream)
if commit_match is None:
    raise SystemExit("UPSTREAM.md does not record an upstream commit SHA")
commit = commit_match.group(1)
if "vendor/atsim" not in notices:
    raise SystemExit("THIRD_PARTY_NOTICES.md does not mention vendor/atsim")
if commit not in notices:
    raise SystemExit("THIRD_PARTY_NOTICES.md does not contain the upstream commit recorded in UPSTREAM.md")
print(f"Verified all {len(manifest)} upstream files; snapshot attribution remains a distribution gate.")
if "PENDING UPSTREAM CONFIRMATION" in notices:
    print("atsim notice is pending upstream confirmation and remains a distribution gate.")
