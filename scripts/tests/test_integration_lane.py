"""Offline integration-lane contracts with every external command stubbed on PATH."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
STUB = r'''import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "python3":
    if "scripts/tests/test_cli.py" in args:
        print("test_export_artifacts_real_tools_produce_complete_artifact_set ... ok", file=sys.stderr)
        print("Ran 1 test in 0.01s", file=sys.stderr)
        if os.environ.get("FAKE_CLI_SKIP") == "1":
            print("OK (skipped=1)", file=sys.stderr)
        else:
            print("OK", file=sys.stderr)
    else:
        os.execv(sys.executable, [sys.executable, *args])
elif name == "swift":
    if args[:1] == ["build"]:
        if "--show-bin-path" in args: print(os.environ["FAKE_BIN"])
    elif args[:1] == ["test"]:
        with open(os.environ["FAKE_SWIFT_TRACE"], "a") as stream:
            stream.write(" ".join(args) + "\n")
        lane = args[-1]
        skip = 1 if os.environ.get("FAKE_SKIP_LANE") == lane else 0
        print(f"Executed 2 tests, with {skip} tests skipped and 0 failures")
        if os.environ.get("FAKE_LOG_TOOL_PATH"):
            print(os.environ["FAKE_LOG_TOOL_PATH"])
elif name == "navcenterctl":
    print(os.environ["FAKE_DOCTOR"])
elif name == "git":
    print("a" * 40)
elif name == "sw_vers":
    print("15.7" if args == ["-productVersion"] else "24G222")
elif name == "atsim":
    pass
elif name == "pdftotext":
    print("pdftotext version 25.01.0", file=sys.stderr)
elif name == "pandoc":
    print(f"pandoc 1.0 {sys.argv[0]}")
elif name == "chrome":
    print("chrome 1.0   ")
else:
    print(f"{name} 1.0")
'''


class IntegrationLaneTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nav-center-integration-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.tools = self.home / "tools"
        self.tools.mkdir()
        self.bin = self.home / "build"
        self.bin.mkdir()
        self.out = self.root / "out"
        self.trace = self.root / "swift-trace"
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy2(REPO / "scripts/integration-acceptance.sh", scripts / "integration-acceptance.sh")
        (scripts / "tests").mkdir()
        (scripts / "tests/test_cli.py").write_text("# Stub intercepts this invocation.\n")
        for name in ("swift", "sw_vers", "pandoc", "pdftotext", "ruby", "atsim", "codex", "python3", "git"):
            self.make_stub(self.tools / name)
        self.make_stub(self.bin / "navcenterctl")
        names = ("atsim", "export-tool", "pandoc", "pdftotext", "chrome", "ruby", "codex")
        overrides = {"atsim": "NAV_CENTER_ATSIM_BIN", "pandoc": "PANDOC_BIN",
                     "pdftotext": "PDFTOTEXT_BIN", "chrome": "CHROME_BIN",
                     "codex": "DASHBOARD_CODEX_BIN"}
        self.doctor = {"tools": [
            {"tool": name, "state": "built-in" if name == "export-tool" else "found",
             "environmentVariable": overrides.get(name),
             "resolvedPath": str(self.tools / ("chrome" if name == "chrome" else name))}
            for name in names]}
        self.make_stub(self.tools / "chrome")
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=f"{self.tools}:{os.environ['PATH']}", FAKE_BIN=str(self.bin),
                        FAKE_SWIFT_TRACE=str(self.trace), NAV_CENTER_ATSIM_BIN=str(self.tools / "atsim"))

    @staticmethod
    def make_stub(path):
        path.write_text(f"#!{sys.executable}\n{STUB}")
        path.chmod(0o755)

    def run_lane(self, **changes):
        env = dict(self.env, FAKE_DOCTOR=json.dumps(self.doctor), **changes)
        return subprocess.run(["bash", "scripts/integration-acceptance.sh", str(self.out)],
                              cwd=self.root, env=env, capture_output=True, text=True)

    def summary(self):
        return json.loads((self.out / "integration-acceptance.json").read_text())

    def test_lane_passes_when_all_tools_present_and_no_skips(self):
        result = self.run_lane()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        summary = self.summary()
        self.assertEqual(summary["result"], "pass")
        self.assertEqual([lane["name"] for lane in summary["lanes"]],
                         ["ats", "chrome", "export", "cli-export"])
        self.assertTrue(all(lane["executed"] > 0 and lane["skipped"] == 0 for lane in summary["lanes"]))
        chrome = next(tool for tool in summary["tools"] if tool["name"] == "chrome")
        self.assertEqual(chrome["version"], "chrome 1.0")

    def test_lane_fails_naming_first_missing_tool_before_running_tests(self):
        self.doctor["tools"][0]["state"] = "missing"
        result = self.run_lane()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL: atsim is required for the integration lane but is missing (set NAV_CENTER_ATSIM_BIN)", result.stderr)
        self.assertFalse(self.trace.exists())
        self.assertEqual(self.summary()["result"], "fail")
        self.assertEqual(self.summary()["lanes"], [])

    def test_lane_fails_when_a_requested_lane_skips(self):
        result = self.run_lane(FAKE_SKIP_LANE="RendererReadinessTests")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        chrome = next(lane for lane in self.summary()["lanes"] if lane["name"] == "chrome")
        self.assertEqual(chrome["skipped"], 1)
        self.assertEqual(chrome["result"], "fail")

    def test_lane_fails_when_cli_export_reports_skipped(self):
        result = self.run_lane(FAKE_CLI_SKIP="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        cli = next(lane for lane in self.summary()["lanes"] if lane["name"] == "cli-export")
        self.assertEqual(cli["skipped"], 1)
        self.assertEqual(cli["result"], "fail")

    def test_override_paths_supply_versions_when_doctor_redacts_paths(self):
        changes = {}
        overrides = self.home / "overrides"
        overrides.mkdir()
        for name, variable in (("pandoc", "PANDOC_BIN"), ("pdftotext", "PDFTOTEXT_BIN"),
                               ("chrome", "CHROME_BIN"), ("codex", "DASHBOARD_CODEX_BIN")):
            item = next(tool for tool in self.doctor["tools"] if tool["tool"] == name)
            item["resolvedPath"] = None
            replacement = overrides / name
            replacement.write_text(f"#!{sys.executable}\nprint('override {name}')\n")
            replacement.chmod(0o755)
            changes[variable] = str(replacement)
        result = self.run_lane(**changes)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        versions = {tool["name"]: tool["version"] for tool in self.summary()["tools"]}
        for name in ("pandoc", "pdftotext", "chrome", "codex"):
            self.assertEqual(versions[name], f"override {name}")

    def test_unknown_doctor_tool_warns_and_writes_summary(self):
        self.doctor["tools"].append({"tool": "future-tool", "state": "found"})
        result = self.run_lane()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("WARN: skipping unknown doctor tool: future-tool", result.stderr)
        self.assertEqual(self.summary()["result"], "pass")

    def test_summary_json_schema_and_home_redaction(self):
        tool_path = str(self.tools / "pandoc")
        result = self.run_lane(FAKE_LOG_TOOL_PATH=tool_path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        summary = self.summary()
        self.assertEqual(set(summary), {"schema", "date", "source_sha", "macos", "arch", "tools", "lanes", "result"})
        self.assertEqual(summary["schema"], 1)
        self.assertIsInstance(summary["tools"], list)
        self.assertEqual(len(summary["tools"]), 7)
        self.assertEqual(set(summary["tools"][0]), {"name", "state", "version"})
        self.assertEqual(set(summary["lanes"][0]),
                         {"name", "command", "exit_status", "executed", "skipped", "failures", "result"})
        for lane in summary["lanes"]:
            for field in ("executed", "skipped", "failures", "exit_status"):
                self.assertIsInstance(lane[field], int)
        pandoc = next(tool for tool in summary["tools"] if tool["name"] == "pandoc")
        self.assertIn("<tool path>", pandoc["version"])
        for name in ("integration-acceptance.json", "integration-acceptance.md"):
            content = (self.out / name).read_text()
            self.assertNotIn(str(self.home), content)
            self.assertNotIn(tool_path, content)
            self.assertNotIn("resolvedPath", content)
        log = (self.out / "chrome.log").read_text()
        self.assertIn("<tool path>", log)
        self.assertNotIn(tool_path, log)
        self.assertNotIn(str(self.home), log)


if __name__ == "__main__":
    unittest.main()
