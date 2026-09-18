"""Synthetic artifact checks; these tests never sign or submit to Apple."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / ".claude/skills/release-evidence/verify-artifact.sh"
STUB = """import json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['EVIDENCE_TRACE'], 'a') as trace:
    trace.write(json.dumps([tool, args]) + '\\n')
allowed = {
    'hdiutil': ['verify'],
    'codesign': ['--verify', '--strict', '--verbose=2'],
    'xcrun': ['stapler', 'validate'],
    'spctl': ['-a', '-t', 'open', '--context', 'context:primary-signature'],
}
sys.exit(0 if args[:-1] == allowed.get(tool) else 99)
"""


class ClaudeReleaseEvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nav-evidence-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.artifact = self.root / "Nav Center-synthetic-macos-arm64.dmg"
        self.artifact.write_bytes(b"synthetic artifact, not a real disk image")
        self.checksum = Path(str(self.artifact) + ".sha256")
        self.notary = Path(str(self.artifact) + ".notary.json")
        self.notary.write_text(json.dumps({"status": "Accepted"}))
        self.write_checksum()
        shims = self.root / "shims"
        shims.mkdir()
        (shims / "python3").symlink_to(sys.executable)
        for name in ("hdiutil", "codesign", "xcrun", "spctl"):
            shim = shims / name
            shim.write_text(f"#!{sys.executable}\n" + STUB)
            shim.chmod(0o700)
        self.trace = self.root / "trace.jsonl"
        self.env = {
            "PATH": str(shims) + os.pathsep + "/usr/bin:/bin",
            "EVIDENCE_TRACE": str(self.trace),
        }

    def write_checksum(self, source=None, filename=None):
        source = source or self.artifact
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        self.checksum.write_text(f"{digest}  {filename or source.name}\n")

    def run_check(self, artifact=None):
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), str(artifact or self.artifact)],
            env=self.env, capture_output=True, text=True, timeout=10,
        )

    def assert_rejected(self, result):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("Artifact-level gates passed", result.stdout)

    def test_matching_artifact_passes_with_clean_machine_limitations(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("checksum sidecar matches artifact", result.stdout)
        self.assertIn("DMG-only checks passed", result.stdout)
        self.assertIn("nested app and embedded CLI signature verification", result.stdout)
        self.assertIn("distribution readiness is not established", result.stdout)
        self.assertNotIn("Artifact-level gates passed", result.stdout)
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertEqual([call[0] for call in calls], ["hdiutil", "codesign", "xcrun", "spctl"])
        self.assertTrue(all(call[1][-1] == str(self.artifact) for call in calls))

    def test_missing_required_sidecars_each_prevent_success(self):
        for sidecar in (self.checksum, self.notary):
            with self.subTest(sidecar=sidecar.suffix):
                contents = sidecar.read_bytes()
                sidecar.unlink()
                result = self.run_check()
                self.assert_rejected(result)
                self.assertIn("MISSING", result.stdout)
                sidecar.write_bytes(contents)

    def test_other_file_with_valid_digest_cannot_satisfy_checksum(self):
        other = self.root / "other.dmg"
        other.write_bytes(b"different synthetic artifact")
        self.write_checksum(source=other)
        self.assert_rejected(self.run_check())

    def test_wrong_filename_rejected_even_with_matching_digest(self):
        other = self.root / "other.dmg"
        other.write_bytes(self.artifact.read_bytes())
        self.write_checksum(source=other)
        self.assert_rejected(self.run_check())

    def test_artifact_changed_after_checksum_rejected(self):
        self.artifact.write_bytes(b"changed synthetic artifact")
        self.assert_rejected(self.run_check())

    def test_unsigned_name_rejected_before_tools_run(self):
        unsigned = self.root / "NavCenter-synthetic-unsigned.dmg"
        unsigned.write_bytes(b"synthetic unsigned artifact")
        result = self.run_check(unsigned)
        self.assert_rejected(result)
        self.assertIn("unsigned local artifact", result.stdout)
        self.assertFalse(self.trace.exists())


if __name__ == "__main__":
    unittest.main()
