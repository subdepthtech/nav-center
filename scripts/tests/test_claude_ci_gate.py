"""Exercise local gate reporting with synthetic tools; never run native builds."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


GATE = Path(__file__).resolve().parents[2] / ".claude/skills/ci-gate/run-gate.sh"


class ClaudeCIGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nav-gate-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.repo / "scripts/tests").mkdir(parents=True)
        self.write_script(self.repo / "scripts/export-coverage.sh", "exit 0\n")
        for name in ("verify-vendor.py", "check-analysis-reports.py", "tests/test_cli.py"):
            (self.repo / "scripts" / name).write_text("")
        (self.repo / "scripts/tests/test_stub.py").write_text(
            "import unittest\nclass Stub(unittest.TestCase):\n"
            "    def test_stub(self):\n        pass\n"
        )
        for name in ("bash", "mkdir", "mktemp", "grep", "tail"):
            tool = shutil.which(name)
            self.assertIsNotNone(tool)
            (self.bin / name).symlink_to(tool)
        (self.bin / "python3").symlink_to(sys.executable)
        self.write_script(self.bin / "git", """
if [ "$1" = rev-parse ] || [ "$1" = merge-base ]; then
  printf 'synthetic-revision\\n'
fi
""")
        self.write_script(self.bin / "xcrun", f"""
case "$*" in
  *--show-bin-path*) printf '%s\\n' {shlex.quote(str(self.bin))} ;;
esac
""")
        self.write_script(self.bin / "xcodebuild", "exit 0\n")
        self.write_script(self.bin / "navcenterctl", "exit 0\n")

    @staticmethod
    def write_script(path, body):
        path.write_text("#!/bin/bash\n" + body)
        path.chmod(0o755)

    def run_gate(self, payload=None, status=0):
        if payload is not None:
            self.write_script(
                self.bin / "swiftlint",
                f"printf '%s\\n' {shlex.quote(payload)}\nexit {status}\n",
            )
        env = dict(os.environ, PATH=str(self.bin), TMPDIR=str(self.root),
                   CLAUDE_PROJECT_DIR=str(self.repo))
        return subprocess.run(["/bin/bash", str(GATE), "--full"], cwd=self.repo,
                              env=env, text=True, capture_output=True, timeout=20)

    def test_clean_report_passes(self):
        result = self.run_gate("[]")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS     swiftlint report generated", result.stdout)

    def test_strict_findings_remain_advisory(self):
        findings = [{"file": "Sources/Example.swift", "rule_id": "identifier_name",
                     "reason": "Name too short", "severity": "Warning"}]
        result = self.run_gate(json.dumps(findings), status=2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS     swiftlint report generated", result.stdout)

    def test_runtime_failure_does_not_pass_even_with_valid_json(self):
        result = self.run_gate("[]", status=139)
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL     swiftlint report generated", result.stdout)
        self.assertIn("exit status 139", result.stdout)

    def test_invalid_reports_fail(self):
        for payload in ("", "not json", "{}", '[{"file": "Sources/Example.swift"}]'):
            with self.subTest(payload=payload):
                result = self.run_gate(payload)
                self.assertEqual(result.returncode, 1)
                self.assertIn("FAIL     swiftlint report generated", result.stdout)

    def test_nonzero_without_findings_fails(self):
        result = self.run_gate("[]", status=2)
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL     swiftlint report generated", result.stdout)

    def test_missing_tool_is_blocked(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 1)
        self.assertIn("BLOCKED  swiftlint report generated", result.stdout)

    def test_mktemp_failure_stops_before_directory_writes(self):
        (self.bin / "mktemp").unlink()
        self.write_script(self.bin / "mktemp", "exit 1\n")
        (self.bin / "mkdir").unlink()
        marker = self.root / "mkdir-was-called"
        self.write_script(self.bin / "mkdir", f": > {shlex.quote(str(marker))}\n")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Unable to create the temporary run directory", result.stderr)
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
