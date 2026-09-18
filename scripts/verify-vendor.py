#!/usr/bin/env python3
"""Check the reviewed ATS snapshot without installing or executing it."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "vendor/atsim"
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
print(f"Verified all {len(manifest)} upstream files; snapshot attribution remains a distribution gate.")
