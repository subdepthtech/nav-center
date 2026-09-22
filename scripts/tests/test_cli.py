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

    def test_doctor_reports_tools_without_writing_to_workspace(self):
        self.assertEqual(self.run_cli("init-workspace", "--workspace", self.workspace).returncode, 0)
        before = self.workspace_listing()
        missing = self.root / "missing-atsim"
        env = dict(self.env, NAV_CENTER_ATSIM_BIN=str(missing))
        result = subprocess.run(
            [os.environ["NAVCENTERCTL"], "doctor", "--json", "--workspace", self.workspace],
            env=env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        tools = json.loads(result.stdout)["tools"]
        self.assertEqual([tool["tool"] for tool in tools], [
            "atsim", "export-tool", "pandoc", "pdftotext", "chrome", "ruby", "codex",
        ])
        self.assertEqual(tools[0]["state"], "override-invalid")
        self.assertEqual(tools[0]["environmentVariable"], "NAV_CENTER_ATSIM_BIN")
        self.assertIsNone(tools[0].get("resolvedPath"))
        self.assertNotIn("/Users/", self.decoded_text(result.stdout))
        self.assertNotIn(str(missing), self.decoded_text(result.stdout))
        self.assertEqual(self.workspace_listing(), before)

    def test_doctor_human_output_lists_every_tool_and_env_var(self):
        self.assertEqual(self.run_cli("init-workspace", "--workspace", self.workspace).returncode, 0)
        result = self.run_cli("doctor", "--workspace", self.workspace)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("atsim", "export-tool", "pandoc", "pdftotext", "chrome", "ruby", "codex"):
            self.assertIn(name, result.stdout)
        for variable in (
            "NAV_CENTER_ATSIM_BIN", "NAV_CENTER_EXPORT_BIN", "PANDOC_BIN",
            "PDFTOTEXT_BIN", "CHROME_BIN", "DASHBOARD_CODEX_BIN",
        ):
            self.assertIn(variable, result.stdout)
        self.assertIn("Tools:", result.stdout)
        self.assertIn(
            "Finder-launched apps do not see your shell PATH. Tools in /opt/homebrew/bin, "
            "/usr/local/bin, or ~/.local/bin are found automatically; otherwise set the variable "
            "with `launchctl setenv NAME /absolute/path` before opening Nav Center.",
            result.stdout,
        )

    def test_feedback_diagnostics_is_redacted_by_default_and_opt_in_is_explicit(self):
        self.assertEqual(self.run_cli("init-workspace", "--workspace", self.workspace).returncode, 0)
        home = str(Path.home())
        default = self.run_cli("feedback-diagnostics", "--workspace", self.workspace)
        self.assertEqual(default.returncode, 0, default.stderr)
        self.assertEqual(json.loads(default.stdout)["workspace"]["path"], "<workspace>")
        self.assertIn("<workspace>", default.stdout)
        redacted = self.decoded_text(default.stdout)
        self.assertNotIn(home, redacted)
        self.assertNotIn(str(self.workspace), redacted)
        alias = self.run_cli("feedback-diagnostics", "--redact", "--workspace", self.workspace)
        self.assertEqual(alias.returncode, 0, alias.stderr)
        self.assertEqual(json.loads(alias.stdout)["workspace"]["path"], "<workspace>")
        opened = self.run_cli("feedback-diagnostics", "--include-unredacted", "--workspace", self.workspace)
        self.assertEqual(opened.returncode, 0, opened.stderr)
        self.assertEqual(json.loads(opened.stdout)["workspace"]["path"], str(self.workspace))
        self.assertNotIn("<workspace>", json.loads(opened.stdout)["workspace"]["path"])
        missing = self.root / "does-not-exist"
        before = sorted(path.relative_to(self.root).as_posix() for path in self.root.rglob("*"))
        bogus = self.run_cli("feedback-diagnostics", "--bogus", "--workspace", missing)
        self.assertNotEqual(bogus.returncode, 0)
        self.assertFalse(missing.exists())
        after = sorted(path.relative_to(self.root).as_posix() for path in self.root.rglob("*"))
        self.assertEqual(before, after)

    def test_feedback_diagnostics_explicit_redact_wins_over_opt_in(self):
        self.assertEqual(self.run_cli("init-workspace", "--workspace", self.workspace).returncode, 0)
        log = self.workspace / "logs" / "example.log"
        log.write_text("Authorization: Bearer SYNTHETIC_TOKEN_NOT_REAL\n")
        for args in (
            ("feedback-diagnostics", "--redact", "--include-unredacted", "--workspace", self.workspace),
            ("feedback-diagnostics", "--include-unredacted", "--redact", "--workspace", self.workspace),
        ):
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = json.loads(result.stdout)
                self.assertEqual(payload["workspace"]["path"], "<workspace>")
                self.assertEqual(payload["recentLogs"], [])
                redacted = self.decoded_text(result.stdout)
                self.assertNotIn("SYNTHETIC_TOKEN", redacted)
                self.assertNotIn(str(self.workspace), redacted)
        opened = self.run_cli("feedback-diagnostics", "--include-unredacted", "--workspace", self.workspace)
        self.assertEqual(opened.returncode, 0, opened.stderr)
        opened_payload = json.loads(opened.stdout)
        self.assertEqual(opened_payload["workspace"]["path"], str(self.workspace))
        self.assertIn("SYNTHETIC_TOKEN_NOT_REAL", opened.stdout)

    def test_redacted_doctor_and_feedback_hide_override_values(self):
        self.assertEqual(self.run_cli("init-workspace", "--workspace", self.workspace).returncode, 0)
        outside = self.root / "acme-contract" / "acme-bin" / "acme-atsim"
        outside.parent.mkdir(parents=True)
        outside.write_text("#!/bin/sh\nexit 0\n")
        outside.chmod(0o755)
        relative = "acme-clients/acme-client/acme-codex"
        env = dict(self.env, NAV_CENTER_ATSIM_BIN=str(outside), DASHBOARD_CODEX_BIN=relative)
        secrets = [
            str(outside), relative, "acme-contract", "acme-bin", "acme-atsim",
            "acme-clients", "acme-client", "acme-codex",
        ]

        doctor = subprocess.run(
            [os.environ["NAVCENTERCTL"], "doctor", "--json", "--workspace", self.workspace],
            env=env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(doctor.returncode, 0, doctor.stderr)
        doctor_payload = json.loads(doctor.stdout)
        doctor_tools = {tool["tool"]: tool for tool in doctor_payload["tools"]}
        self.assertEqual(doctor_tools["atsim"]["state"], "found")
        self.assertEqual(doctor_tools["atsim"]["source"], "environment")
        self.assertIsNone(doctor_tools["atsim"].get("resolvedPath"))
        self.assertEqual(
            doctor_tools["atsim"]["summary"],
            "Found via NAV_CENTER_ATSIM_BIN (path hidden in redacted output)",
        )
        self.assertEqual(doctor_tools["codex"]["state"], "override-invalid")
        self.assertIsNone(doctor_tools["codex"].get("resolvedPath"))
        self.assertEqual(doctor_tools["codex"]["summary"], "DASHBOARD_CODEX_BIN must be an absolute path")
        doctor_text = self.decoded_text(doctor.stdout)
        for secret in secrets:
            self.assertNotIn(secret, doctor_text)

        feedback = subprocess.run(
            [os.environ["NAVCENTERCTL"], "feedback-diagnostics", "--workspace", self.workspace],
            env=env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(feedback.returncode, 0, feedback.stderr)
        feedback_payload = json.loads(feedback.stdout)
        feedback_tools = {tool["tool"]: tool for tool in feedback_payload["tools"]}
        self.assertIsNone(feedback_tools["atsim"].get("resolvedPath"))
        self.assertEqual(
            feedback_tools["atsim"]["summary"],
            "Found via NAV_CENTER_ATSIM_BIN (path hidden in redacted output)",
        )
        self.assertIsNone(feedback_tools["codex"].get("resolvedPath"))
        self.assertEqual(feedback_tools["codex"]["summary"], "DASHBOARD_CODEX_BIN must be an absolute path")
        feedback_text = self.decoded_text(feedback.stdout)
        for secret in secrets:
            self.assertNotIn(secret, feedback_text)

    def decoded_text(self, stdout):
        values = []

        def walk(value):
            if isinstance(value, str):
                values.append(value)
            elif isinstance(value, dict):
                for item in value.values():
                    walk(item)
            elif isinstance(value, list):
                for item in value:
                    walk(item)

        walk(json.loads(stdout))
        return "\n".join(values)

    def workspace_listing(self):
        return sorted(str(path.relative_to(self.workspace)) for path in self.workspace.rglob("*"))


if __name__ == "__main__":
    unittest.main()
