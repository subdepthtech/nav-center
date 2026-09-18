"""Negative checks for report boundaries; all inputs are synthetic."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("reports", Path(__file__).resolve().parents[1] / "check-analysis-reports.py")
REPORTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORTS)
BOOTSTRAP_SPEC = importlib.util.spec_from_file_location(
    "bootstrap_tools", Path(__file__).resolve().parents[1] / "bootstrap-tools.py"
)
BOOTSTRAP = importlib.util.module_from_spec(BOOTSTRAP_SPEC)
BOOTSTRAP_SPEC.loader.exec_module(BOOTSTRAP)


class BootstrapToolsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nav-bootstrap-synthetic-")
        self.addCleanup(self.temp.cleanup)
        self.destination = Path(self.temp.name)
        self.binary = b"synthetic executable bytes"
        archive_data = io.BytesIO()
        with tarfile.open(fileobj=archive_data, mode="w:gz") as archive:
            member = tarfile.TarInfo("release/synthetic-tool")
            member.size = len(self.binary)
            archive.addfile(member, io.BytesIO(self.binary))
        self.archive = archive_data.getvalue()
        self.entry = {
            "url": "https://github.com/example/releases/download/v1/tool.tar.gz",
            "sha256": hashlib.sha256(self.archive).hexdigest(),
        }

    def response(self, data):
        return io.BytesIO(data)

    def test_stale_download_does_not_block_verified_install(self):
        stale = self.destination / "synthetic-tool.download"
        stale.write_bytes(b"interrupted old download")
        with patch.object(BOOTSTRAP.urllib.request, "urlopen", return_value=self.response(self.archive)):
            BOOTSTRAP.install("synthetic-tool", self.entry, self.destination)
        installed = self.destination / "synthetic-tool"
        self.assertEqual(installed.read_bytes(), self.binary)
        self.assertEqual(installed.stat().st_mode & 0o777, 0o755)
        self.assertEqual(stale.read_bytes(), b"interrupted old download")
        self.assertEqual(list(self.destination.glob(".synthetic-tool.download.*")), [])

    def test_checksum_mismatch_installs_nothing(self):
        entry = self.entry | {"sha256": "0" * 64}
        with (patch.object(BOOTSTRAP.urllib.request, "urlopen", return_value=self.response(self.archive)),
              self.assertRaisesRegex(ValueError, "Checksum mismatch")):
            BOOTSTRAP.install("synthetic-tool", entry, self.destination)
        self.assertFalse((self.destination / "synthetic-tool").exists())
        self.assertEqual(list(self.destination.glob(".synthetic-tool.download.*")), [])


class AnalysisReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nav-analysis-synthetic-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / "Sources").mkdir()
        self.source = self.root / "Sources/Example.swift"
        self.source.write_text("func example() {}\n")
        self.reports = self.root / "reports"
        self.reports.mkdir()
        self.write_reports(str(self.source))

    def write_reports(self, filename, lines=1, findings=None):
        (self.reports / "coverage.json").write_text(json.dumps({"data": [{"files": [{"filename": filename, "summary": {"lines": {"count": lines, "covered": lines}}}]}]}))
        (self.reports / "swift-coverage.txt").write_text(filename + ":\n    1|      1|func example() {}\n")
        (self.reports / "swiftlint.json").write_text(json.dumps(findings or []))

    def prepare(self):
        with patch.object(REPORTS.subprocess, "check_output", return_value="synthetic-revision\n"), contextlib.redirect_stdout(io.StringIO()):
            REPORTS.prepare(self.root, self.reports)

    def test_preserves_counts_relativizes_paths_and_accepts_no_findings(self):
        self.prepare()
        summary = json.loads((self.reports / "analysis-summary.json").read_text())
        self.assertEqual(summary["executable_lines"], 1)
        self.assertEqual(summary["covered_lines"], 1)
        self.assertEqual(summary["swiftlint_findings"], 0)
        self.assertTrue((self.reports / "swift-coverage.txt").read_text().startswith("Sources/Example.swift:\n"))

    def test_rejects_empty_coverage(self):
        self.write_reports(str(self.source), lines=0)
        with self.assertRaisesRegex(ValueError, "Empty coverage"):
            self.prepare()

    def test_rejects_external_or_unmaintained_paths(self):
        for filename in ("/private/synthetic.swift", "vendor/synthetic.swift", "../synthetic.swift"):
            with self.subTest(filename=filename):
                self.write_reports(filename)
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse((self.reports / "analysis-summary.json").exists())

    def test_rejects_symlink_escape(self):
        outside = self.root / "outside.swift"
        outside.write_text("synthetic\n")
        self.source.unlink()
        self.source.symlink_to(outside)
        with self.assertRaises(ValueError):
            self.prepare()

    def test_rejects_mismatched_text_report(self):
        (self.reports / "swift-coverage.txt").write_text("Sources/Unknown.swift:\n")
        with self.assertRaises(ValueError):
            self.prepare()

    def test_rejects_impossible_line_counts(self):
        coverage = json.loads((self.reports / "coverage.json").read_text())
        coverage["data"][0]["files"][0]["summary"]["lines"]["covered"] = 2
        (self.reports / "coverage.json").write_text(json.dumps(coverage))
        with self.assertRaisesRegex(ValueError, "Invalid coverage line counts"):
            self.prepare()

    def test_rejects_external_linter_path_without_rewriting_coverage(self):
        self.write_reports(str(self.source), findings=[{"file": "/private/synthetic.swift"}])
        original = (self.reports / "swift-coverage.txt").read_bytes()
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual((self.reports / "swift-coverage.txt").read_bytes(), original)


class WorkflowFailureTests(unittest.TestCase):
    def test_native_test_failures_survive_log_capture(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        # GitHub's explicit bash shell uses -eo pipefail; unspecified shells do not.
        self.assertIn("defaults:\n  run:\n    shell: bash\n", workflow)
        commands = [line.strip() for line in workflow.splitlines()
                    if line.strip().startswith("swift test ") and "| tee " in line]
        self.assertEqual(len(commands), 3)  # Coverage, ASAN, TSAN must propagate failure.
        with tempfile.TemporaryDirectory(prefix="nav-ci-failure-") as directory:
            root = Path(directory)
            (root / "reports/native").mkdir(parents=True)
            (root / "bin").mkdir()
            swift = root / "bin/swift"
            swift.write_text("#!/bin/sh\necho 'Synthetic test failure'\nexit 42\n")
            swift.chmod(0o755)
            env = {"PATH": str(root / "bin") + os.pathsep + os.defpath, "RUNNER_TEMP": str(root)}
            for command in commands:
                with self.subTest(command=command):
                    result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", command],
                                            cwd=root, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 42, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
