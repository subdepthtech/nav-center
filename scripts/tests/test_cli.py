"""Black-box CLI regressions. Set NAVCENTERCTL to the built executable."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.environ.get("NAVCENTERCTL"), "Run after build with NAVCENTERCTL set")
class CLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="navcenter-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.workspace = self.root / "workspace"
        self.env = dict(os.environ, NAV_CENTER_WORKSPACE_ROOT=str(self.workspace))

    def run_cli(self, *args):
        return subprocess.run([os.environ["NAVCENTERCTL"], *map(str, args)], env=self.env,
                              capture_output=True, text=True, timeout=15)

    def test_invalid_invocations_never_initialize_workspace(self):
        for args in [("init-workspace", "--workspace"),
                     ("init-workspace", "--workspace", "--bogus"),
                     ("init-workspace", "--workspce", self.workspace),
                     ("init-workspace", "unexpected"),
                     ("init-workspace", "--workspace", self.workspace, "--workspace", self.root / "other"),
                     ("init-workspace", "--dry-run"),
                     ("unknown",), ("doctor", "--json", "--json")]:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(self.workspace.exists())
                self.assertFalse((self.root / "other").exists())

    def test_help_and_fresh_workspace_doctor(self):
        self.assertEqual(self.run_cli("--help").returncode, 0)
        self.assertFalse(self.workspace.exists())
        result = self.run_cli("init-workspace", "--workspace", self.workspace)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = self.run_cli("doctor", "--json", "--workspace", self.workspace)
        self.assertEqual(report.returncode, 0, report.stderr)
        self.assertEqual(json.loads(report.stdout)["workspace"]["requiredDirectoriesMissing"], [])
        self.assertTrue((self.workspace / "templates/resume.css").is_file())

    def test_creation_dry_run_commit_duplicate_and_bad_date(self):
        self.assertEqual(self.run_cli("init-workspace").returncode, 0)
        source = self.workspace / "job.md"
        source.write_text("Responsibilities and requirements. " + "Experience building synthetic systems. " * 30)
        args = ["create-package", "--company", "Synthetic Café", "--role", "Engineer", "--posting", "job.md", "--date", "2026-09-04"]
        preview = self.run_cli(*args, "--dry-run")
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertEqual(list((self.workspace / "applications").iterdir()), [])
        created = self.run_cli(*args)
        self.assertEqual(created.returncode, 0, created.stderr)
        package = self.workspace / "applications" / json.loads(created.stdout)["packageName"]
        self.assertTrue(list(package.glob("Resume_*.md")))
        self.assertTrue((package / "artifacts").is_dir())
        prior = (package / "posting.md").read_bytes()
        self.assertNotEqual(self.run_cli(*args).returncode, 0)
        args[-1] = "2026-02-30"
        self.assertNotEqual(self.run_cli(*args).returncode, 0)
        self.assertEqual((package / "posting.md").read_bytes(), prior)

    def test_repeated_imports_and_failed_batch_preserve_workspace(self):
        first, second = self.root / "one.txt", self.root / "two.txt"
        first.write_text("Synthetic document one.")
        second.write_text("Synthetic document two.")
        result = self.run_cli("import-docs", "--file", first, "--file", second)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)), 2)
        before = sorted(str(p.relative_to(self.workspace)) for p in self.workspace.rglob("*"))
        result = self.run_cli("import-docs", "--file", first, "--file", self.root / "missing.txt")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sorted(str(p.relative_to(self.workspace)) for p in self.workspace.rglob("*")), before)


if __name__ == "__main__":
    unittest.main()
