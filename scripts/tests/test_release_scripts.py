"""Offline release regressions: all signing/notary/build processes are synthetic stubs."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
SBOM_SPEC = importlib.util.spec_from_file_location("export_sbom", REPO / "scripts/export-sbom.py")
SBOM = importlib.util.module_from_spec(SBOM_SPEC)
SBOM_SPEC.loader.exec_module(SBOM)
STUB = r'''import json, os, pathlib, shutil, stat, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
event = name
if name == "xcrun": event += ":" + ":".join(args[:2])
if name == "spctl": event += ":" + args[args.index("-t") + 1]
if name == "codesign": event += ":verify" if "--verify" in args else ":sign"
if name == "gitleaks": event += ":" + args[0]
if name == "git": event += ":status" if "status" in args else ":rev-parse"
payload = {"tool": name, "args": args, "event": event}
if name == "hdiutil" and args[:1] == ["create"] and "-srcfolder" in args:
    source = pathlib.Path(args[args.index("-srcfolder") + 1])
    payload["srcfolder"] = sorted(child.name for child in source.iterdir())
with open(os.environ["RELEASE_TRACE"], "a") as stream:
    stream.write(json.dumps(payload) + "\n")
if os.environ.get("FAIL_EVENT") == event: sys.exit(9)
if name == "git" and "--is-shallow-repository" in args: print(os.environ.get("RELEASE_SHALLOW", "false"))
if name == "git" and "status" in args and os.environ.get("RELEASE_DIRTY"): print(" M synthetic.swift")
if name == "swift" and "--show-bin-path" in args: print(os.environ["RELEASE_BIN"])
if name == "sips": pathlib.Path(args[args.index("--out") + 1]).write_bytes(b"synthetic PNG")
if name == "iconutil": pathlib.Path(args[args.index("-o") + 1]).write_bytes(b"synthetic ICNS")
if name == "lipo": print(os.environ.get("RELEASE_LIPO_ARCH", os.uname().machine))
if name == "hdiutil" and args[0] == "create": pathlib.Path(args[-1]).write_bytes(b"synthetic DMG")
if name == "hdiutil" and args[:1] == ["attach"] and "-mountpoint" in args:
    source = os.environ.get("FAKE_MOUNT_SOURCE")
    if source:
        mount = pathlib.Path(args[args.index("-mountpoint") + 1])
        mount.mkdir(parents=True, exist_ok=True)
        for child in pathlib.Path(source).iterdir():
            destination = mount / child.name
            if child.is_dir():
                shutil.copytree(child, destination)
            else:
                shutil.copy2(child, destination)
if name == "hdiutil" and args[:1] == ["detach"]:
    sys.exit(0)
if name == "xcrun" and args[:2] == ["notarytool", "submit"]:
    key = pathlib.Path(args[args.index("--key") + 1])
    assert stat.S_IMODE(key.stat().st_mode) == 0o600
    assert "APP_STORE_CONNECT_PRIVATE_KEY" not in os.environ
    print(json.dumps({"id": "synthetic-id", "status": os.environ.get("NOTARY_STATUS", "Accepted")}))
if name == "xcrun" and args[:2] == ["stapler", "staple"]:
    with open(args[2], "ab") as stream: stream.write(b"synthetic ticket")
'''


class SBOMExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nav-center-sbom-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / "dependencies.spdx.json"
        self.metadata = self.output.with_suffix(".metadata.json")
        self.report_url = (
            "https://api.github.com/repos/subdepthtech/nav-center/"
            "dependency-graph/sbom/fetch-report/12345678-abcd"
        )
        self.generate = (200, json.dumps({"sbom_url": self.report_url}))

    def run_export(self, responses, monotonic):
        self.api_calls = []
        response_iterator = iter(responses)

        def fake_run(command, **_kwargs):
            self.api_calls.append(command[-1])
            status, body = next(response_iterator)
            stdout = (
                f"HTTP/2.0 {status} Synthetic\n"
                "content-type: application/json\n\n"
                f"{body}"
            )
            return subprocess.CompletedProcess(
                command, 0 if 200 <= status < 300 else 1,
                stdout=stdout, stderr="",
            )

        with (patch.object(SBOM.subprocess, "run", side_effect=fake_run),
              patch.object(SBOM.time, "monotonic", side_effect=monotonic),
              patch.object(SBOM.time, "sleep") as sleep,
              patch.object(sys, "argv", ["export-sbom.py", str(self.output)]),
              contextlib.redirect_stdout(io.StringIO())):
            self.sleep = sleep
            SBOM.main()
        return self.sleep

    def assert_no_evidence(self):
        self.assertFalse(self.output.exists())
        self.assertFalse(self.metadata.exists())

    def report_poll_count(self):
        return self.api_calls.count(self.report_url)

    def test_202_then_200_writes_spdx_document_and_metadata(self):
        sbom = {"spdxVersion": "SPDX-2.3", "packages": [{"name": "synthetic"}]}
        sleep = self.run_export(
            [self.generate, (202, "{}"), (200, json.dumps(sbom))],
            [0, 0, 1, 4],
        )
        self.assertEqual(len(self.api_calls), 3)
        self.assertEqual(self.report_poll_count(), 2)
        sleep.assert_called_once_with(3)
        self.assertEqual(json.loads(self.output.read_text()), sbom)
        metadata = json.loads(self.metadata.read_text())
        self.assertEqual(metadata["packages"], 1)
        self.assertEqual(metadata["sha256"], hashlib.sha256(self.output.read_bytes()).hexdigest())

    def test_persistently_202_exits_at_deadline_without_evidence(self):
        with self.assertRaisesRegex(SystemExit, "not ready within 60 seconds"):
            self.run_export(
                [self.generate, (202, "{}"), (202, "{}")],
                [0, 0, 1, 4, 5, 60],
            )
        self.assertEqual(len(self.api_calls), 3)
        self.assertEqual(self.report_poll_count(), 2)
        self.assertEqual(self.sleep.call_count, 2)
        self.assert_no_evidence()

    def test_missing_spdx_version_fails_after_one_poll_without_evidence(self):
        with self.assertRaises(SystemExit) as raised:
            self.run_export([self.generate, (200, "{}")], [0, 0])
        self.assertIn("missing spdxVersion", str(raised.exception))
        self.assertNotIn("not ready", str(raised.exception))
        self.assertEqual(self.report_poll_count(), 1)
        self.assert_no_evidence()

    def test_json_array_fails_after_one_poll_without_evidence(self):
        with self.assertRaisesRegex(SystemExit, "not a JSON object"):
            self.run_export([self.generate, (200, "[]")], [0, 0])
        self.assertEqual(self.report_poll_count(), 1)
        self.assert_no_evidence()

    def test_malformed_json_fails_without_retry_or_evidence(self):
        with self.assertRaisesRegex(SystemExit, "invalid JSON"):
            self.run_export([self.generate, (200, "not-json")], [0, 0])
        self.assertEqual(self.report_poll_count(), 1)
        self.assert_no_evidence()

    def test_wrong_schema_fails_without_retry_or_evidence(self):
        wrong_schema = {"spdxVersion": "not-spdx", "packages": []}
        with self.assertRaisesRegex(SystemExit, "invalid SPDX schema"):
            self.run_export(
                [self.generate, (200, json.dumps(wrong_schema))], [0, 0]
            )
        self.assertEqual(self.report_poll_count(), 1)
        self.assert_no_evidence()


class ReleaseScriptsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nav-center-release-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "Resources").mkdir()
        (self.root / "Resources/AppIcon.png").write_bytes(b"synthetic icon source")
        (self.root / "LICENSE").write_text("Synthetic Nav Center license.\n")
        (self.root / "THIRD_PARTY_NOTICES.md").write_text("Synthetic third-party notices.\n")
        for script in (REPO / "scripts").glob("*.sh"):
            shutil.copy2(script, self.root / "scripts" / script.name)
        self.bin = self.root / "built"
        self.bin.mkdir()
        for product in ("NavCenterApp", "navcenterctl"):
            (self.bin / product).write_bytes(b"synthetic executable")
        self.shims = self.root / "shims"
        self.shims.mkdir()
        for tool in ("swift", "sips", "iconutil", "codesign", "spctl", "xcrun", "hdiutil", "lipo", "pkill", "git", "gitleaks"):
            path = self.shims / tool
            path.write_text(f"#!{sys.executable}\n" + STUB)
            path.chmod(0o700)
        self.trace = self.root / "trace.jsonl"
        self.dist = self.root / "dist"
        self.env = {
            "PATH": str(self.shims) + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "RELEASE_TRACE": str(self.trace),
            "RELEASE_BIN": str(self.bin),
            "NAV_CENTER_DIST_DIR": str(self.dist),
            "NAV_CENTER_VERSION": "9.8.7-beta.2",
            "NAV_CENTER_BUILD": "42",
        }

    def run_script(self, name, *args, extra=None):
        return subprocess.run(["/bin/bash", str(self.root / "scripts" / name), *args],
                              env=self.env | (extra or {}), capture_output=True, text=True)

    def events(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def credentials(self):
        return {
            "DEVELOPER_ID_APPLICATION": "Developer ID Application: Synthetic (TEST)",
            "APP_STORE_CONNECT_KEY_ID": "SYNTHETIC",
            "APP_STORE_CONNECT_ISSUER_ID": "SYNTHETIC",
            "APP_STORE_CONNECT_PRIVATE_KEY": "SYNTHETIC NOT A CREDENTIAL",
        }

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_build_versions_configuration_and_escaped_workspace(self):
        workspace = str(self.root / "A&B<workspace>")
        self.assert_ok(self.run_script("build-and-run.sh", "build", extra={
            "NAV_CENTER_BUILD_CONFIGURATION": "release", "NAV_CENTER_INCLUDE_WORKSPACE_ENV": "1",
            "NAV_CENTER_WORKSPACE_ROOT": workspace}))
        metadata = plistlib.loads((self.dist / "Nav Center.app/Contents/Info.plist").read_bytes())
        self.assertEqual(metadata["CFBundleShortVersionString"], "9.8.7")
        self.assertEqual(metadata["CFBundleVersion"], "42")
        self.assertEqual(metadata["NavCenterVersion"], "9.8.7-beta.2")
        self.assertEqual(metadata["LSEnvironment"]["NAV_CENTER_WORKSPACE_ROOT"], workspace)
        calls = self.events()
        self.assertFalse(any(call["tool"] == "pkill" for call in calls))
        swift_calls = [call["args"] for call in calls if call["tool"] == "swift"]
        self.assertEqual(len(swift_calls), 4)
        self.assertTrue(all(args[args.index("-c") + 1] == "release" for args in swift_calls))

    def test_invalid_build_inputs_fail_before_side_effects(self):
        cases = [("nonsense", {}), ("build", {"NAV_CENTER_VERSION": "1.2.3/../../escape"}),
                 ("build", {"NAV_CENTER_BUILD": "0"}), ("build", {"NAV_CENTER_BUILD_CONFIGURATION": "other"}),
                 ("--verify", {})]
        for mode, env in cases:
            with self.subTest(mode=mode, env=env):
                self.assertNotEqual(self.run_script("build-and-run.sh", mode, extra=env).returncode, 0)
                self.assertFalse(self.dist.exists())
                self.assertEqual(self.events(), [])

    def test_distribution_requires_each_credential_before_build(self):
        for key in (*self.credentials(), "NAV_CENTER_VERSION", "NAV_CENTER_BUILD"):
            credentials = self.credentials() | {key: ""}
            with self.subTest(key=key):
                result = self.run_script("package-beta-dmg.sh", "--distribution", extra=credentials)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.events(), [])
                self.assertFalse(self.dist.exists())

    def test_local_package_never_signs_or_submits(self):
        self.assert_ok(self.run_script("package-beta-dmg.sh", "--local", extra=self.credentials()))
        image = next(self.dist.glob("*-unsigned.dmg"))
        self.assertTrue(Path(str(image) + ".sha256").read_text().startswith(hashlib.sha256(image.read_bytes()).hexdigest()))
        self.assertFalse(any(e["tool"] in ("codesign", "xcrun", "spctl", "pkill") for e in self.events()))
        metadata = plistlib.loads((self.dist / "Nav Center.app/Contents/Info.plist").read_bytes())
        self.assertNotIn("LSEnvironment", metadata)

    def test_distribution_signs_inside_out_and_hashes_final_bytes(self):
        self.assert_ok(self.run_script("package-beta-dmg.sh", "--distribution", extra=self.credentials()))
        image = next(self.dist.glob("*.dmg"))
        self.assertTrue(image.read_bytes().endswith(b"synthetic ticket"))
        checksum = Path(str(image) + ".sha256").read_text()
        self.assertEqual(checksum.split()[0], hashlib.sha256(image.read_bytes()).hexdigest())
        self.assertEqual(checksum.split()[1], image.name)
        events = self.events()
        signs = [e["args"] for e in events if e["event"] == "codesign:sign"]
        self.assertEqual(len(signs), 3)
        self.assertTrue(signs[0][-1].endswith("/Contents/MacOS/navcenterctl"))
        self.assertTrue(signs[1][-1].endswith("/Nav Center.app"))
        self.assertTrue(signs[2][-1].endswith(".dmg"))
        self.assertTrue(all("--deep" not in args and "--timestamp" in args for args in signs))
        self.assertTrue(all("runtime" in args for args in signs[:2]))
        sequence = [e["event"] for e in events]
        self.assertLess(sequence.index("xcrun:notarytool:submit"), sequence.index("xcrun:stapler:staple"))
        self.assertLess(sequence.index("xcrun:stapler:validate"), sequence.index("spctl:open"))
        self.assertIn("spctl:execute", sequence)

    def test_rejected_notary_and_failed_staple_do_not_emit_checksum(self):
        for condition in ({"NOTARY_STATUS": "Invalid"}, {"FAIL_EVENT": "xcrun:notarytool:submit"}, {"FAIL_EVENT": "xcrun:stapler:staple"},
                          {"FAIL_EVENT": "xcrun:stapler:validate"}, {"FAIL_EVENT": "spctl:open"}):
            with self.subTest(condition=condition):
                image = self.root / (str(len(list(self.root.glob("*.dmg")))) + ".dmg")
                image.write_bytes(b"synthetic signed image")
                result = self.run_script("notarize-dmg.sh", str(image), extra=self.credentials() | condition)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(Path(str(image) + ".sha256").exists())

    def test_failed_notary_submission_retains_diagnostic_and_retry_succeeds(self):
        image = self.root / "retry.dmg"
        image.write_bytes(b"synthetic signed image")
        report = Path(str(image) + ".notary.json")

        failed = self.run_script(
            "notarize-dmg.sh", str(image),
            extra=self.credentials() | {"FAIL_EVENT": "xcrun:notarytool:submit"},
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse(report.exists())
        self.assertEqual(list(self.root.glob(".notary.*")), [])
        diagnostics = list(self.root.glob(f".{image.name}.notary-failure.*"))
        self.assertEqual(len(diagnostics), 1)
        self.assertIn(str(diagnostics[0]), failed.stderr)

        self.assert_ok(self.run_script("notarize-dmg.sh", str(image), extra=self.credentials()))
        self.assertEqual(json.loads(report.read_text())["status"], "Accepted")
        self.assertTrue(diagnostics[0].exists())
        self.assertIn("xcrun:stapler:staple", [event["event"] for event in self.events()])

    def test_rejected_notary_retains_submission_json_without_publishing_sidecar(self):
        image = self.root / "rejected.dmg"
        image.write_bytes(b"synthetic signed image")
        result = self.run_script(
            "notarize-dmg.sh", str(image),
            extra=self.credentials() | {"NOTARY_STATUS": "Invalid"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(Path(str(image) + ".notary.json").exists())
        self.assertEqual(list(self.root.glob(".notary.*")), [])
        diagnostics = list(self.root.glob(f".{image.name}.notary-failure.*"))
        self.assertEqual(len(diagnostics), 1)
        self.assertEqual(json.loads(diagnostics[0].read_text())["id"], "synthetic-id")
        self.assertEqual(json.loads(diagnostics[0].read_text())["status"], "Invalid")
        self.assertIn(str(diagnostics[0]), result.stderr)
        self.assertNotEqual(diagnostics[0], Path(str(image) + ".notary.json"))

    def test_signing_or_architecture_failure_stops_before_notary(self):
        for condition in ({"FAIL_EVENT": "codesign:sign"}, {"RELEASE_LIPO_ARCH": "wrong"}):
            with self.subTest(condition=condition):
                result = self.run_script("package-beta-dmg.sh", "--distribution", extra=self.credentials() | condition)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(e["tool"] == "xcrun" for e in self.events()))
                self.assertEqual(list(self.dist.glob("*.dmg")), [])

    def test_existing_distribution_image_is_not_overwritten(self):
        self.dist.mkdir()
        image = self.dist / f"NavCenter-9.8.7-beta.2-macos-{os.uname().machine}.dmg"
        image.write_bytes(b"existing artifact")
        self.assertNotEqual(self.run_script("package-beta-dmg.sh", "--distribution", extra=self.credentials()).returncode, 0)
        self.assertEqual(image.read_bytes(), b"existing artifact")
        self.assertFalse(any(e["tool"] in ("swift", "codesign", "xcrun", "hdiutil") for e in self.events()))

    def test_retained_notary_diagnostic_does_not_block_package_retry(self):
        self.dist.mkdir()
        image_name = f"NavCenter-9.8.7-beta.2-macos-{os.uname().machine}.dmg"
        diagnostic = self.dist / f".{image_name}.notary-failure.previous"
        diagnostic.write_text('{"id":"previous-failed-submission","status":"Invalid"}\n')

        result = self.run_script("package-beta-dmg.sh", "--distribution", extra=self.credentials())

        self.assert_ok(result)
        self.assertTrue(diagnostic.exists())
        self.assertTrue((self.dist / image_name).exists())
        self.assertTrue(Path(str(self.dist / image_name) + ".notary.json").exists())

    def test_failed_hygiene_or_incomplete_source_stops_before_build(self):
        for condition in ({"FAIL_EVENT": "gitleaks:dir"}, {"FAIL_EVENT": "gitleaks:git"}, {"FAIL_EVENT": "git:status"},
                          {"RELEASE_SHALLOW": "true"}, {"RELEASE_DIRTY": "1"}):
            with self.subTest(condition=condition):
                result = self.run_script("package-beta-dmg.sh", "--distribution", extra=self.credentials() | condition)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(e["tool"] in ("swift", "codesign", "xcrun", "hdiutil") for e in self.events()))

    def test_missing_gitleaks_stops_before_build(self):
        (self.shims / "gitleaks").rename(self.shims / "gitleaks-unavailable")
        result = self.run_script("package-beta-dmg.sh", "--distribution", extra=self.credentials())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("preinstalled Gitleaks", result.stderr)
        self.assertEqual(self.events(), [])

    def test_gatekeeper_rejection_fails_distribution(self):
        result = self.run_script("package-beta-dmg.sh", "--distribution", extra=self.credentials() | {"FAIL_EVENT": "spctl:execute"})
        self.assertNotEqual(result.returncode, 0)

    def test_standalone_finalization_replaces_old_checksum(self):
        image = self.root / "synthetic.dmg"
        image.write_bytes(b"synthetic signed image")
        sidecar = Path(str(image) + ".sha256")
        sidecar.write_text(hashlib.sha256(image.read_bytes()).hexdigest() + "  " + image.name + "\n")
        self.assert_ok(self.run_script("notarize-dmg.sh", str(image), extra=self.credentials()))
        self.assertEqual(sidecar.read_text().split()[0], hashlib.sha256(image.read_bytes()).hexdigest())

    def accepted_notary(self, name="accepted.notary.json", status="Accepted"):
        path = self.root / name
        path.write_text(json.dumps({"status": status}) + "\n")
        return path

    def test_cask_guards_each_supported_architecture(self):
        notary = self.accepted_notary()
        for architecture in ("arm64", "x86_64"):
            path = self.root / f"{architecture}.rb"
            url = f"https://example.org/NavCenter-9.8.7-beta.2-macos-{architecture}.dmg"
            self.assert_ok(self.run_script(
                "update-homebrew-cask.sh", "9.8.7-beta.2", url, "a" * 64, architecture, str(path), str(notary),
            ))
            text = path.read_text()
            self.assertIn(f"depends_on arch: :{architecture}", text)
            self.assertIn(
                'caveats "Nav Center #{version} is Developer ID signed, notarized by Apple, and stapled."',
                text,
            )
            self.assertNotIn("arm64 only", text)
            syntax = subprocess.run(["/usr/bin/ruby", "-c", str(path)], capture_output=True, text=True)
            self.assert_ok(syntax)
        self.assertEqual(self.events(), [])

    def test_cask_rejects_mismatched_or_unsigned_assets_before_writing(self):
        notary = self.accepted_notary()
        path = self.root / "invalid.rb"
        for url in ("https://example.org/NavCenter-9.8.7-beta.2-macos-x86_64.dmg",
                    "https://example.org/NavCenter-9.8.7-beta.2-macos-arm64-unsigned.dmg",
                    'https://example.org/"#{system("false")}/NavCenter-9.8.7-beta.2-macos-arm64.dmg'):
            result = self.run_script(
                "update-homebrew-cask.sh", "9.8.7-beta.2", url, "a" * 64, "arm64", str(path), str(notary),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(path.exists())

    def test_cask_caveat_requires_accepted_notary_evidence(self):
        notary = self.accepted_notary(status="accepted")
        path = self.root / "nav-center.rb"
        url = "https://example.org/NavCenter-9.8.7-beta.2-macos-arm64.dmg"
        self.assert_ok(self.run_script(
            "update-homebrew-cask.sh", "9.8.7-beta.2", url, "a" * 64, "arm64", str(path), str(notary),
        ))
        text = path.read_text()
        self.assertIn(
            'caveats "Nav Center #{version} is Developer ID signed, notarized by Apple, and stapled."',
            text,
        )
        self.assertIn('"~/Library/Application Support/Nav Center"', text)
        self.assertIn('"~/Library/Preferences/com.subdepthtech.navcenter.plist"', text)
        self.assertIn('"~/Library/Saved Application State/com.subdepthtech.navcenter.savedState"', text)
        self.assertIn('depends_on macos: ">= :ventura"', text)
        syntax = subprocess.run(["/usr/bin/ruby", "-c", str(path)], capture_output=True, text=True)
        self.assert_ok(syntax)

    def test_cask_refuses_when_notary_evidence_missing(self):
        path = self.root / "nav-center.rb"
        url = "https://example.org/NavCenter-9.8.7-beta.2-macos-arm64.dmg"
        rejected = self.root / "rejected.notary.json"
        rejected.write_text('{"status": "Invalid"}\n')
        malformed = self.root / "malformed.notary.json"
        malformed.write_text("{not json\n")
        missing = self.root / "missing.notary.json"
        for notary in (missing, rejected, malformed):
            with self.subTest(notary=notary.name):
                result = self.run_script(
                    "update-homebrew-cask.sh", "9.8.7-beta.2", url, "a" * 64, "arm64", str(path), str(notary),
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(str(notary), result.stderr)
                self.assertFalse(path.exists())

    def test_workflow_upload_follows_required_gates_and_uses_least_privilege(self):
        release = (REPO / ".github/workflows/beta-release.yml").read_text()
        ci = (REPO / ".github/workflows/ci.yml").read_text()
        for workflow in (release, ci):
            self.assertNotIn("contents: write", workflow)
            self.assertIn("persist-credentials: false", workflow)
            for reference in re.findall(r"uses:\s*(\S+)", workflow):
                self.assertRegex(reference, r"^actions/[a-z-]+@[0-9a-f]{40}$")
        self.assertIn("fetch-depth: 0", release)
        self.assertIn("command -v gitleaks", release)
        self.assertIn("gitleaks dir .", release)
        self.assertIn('gitleaks git . --log-opts="--all"', release)
        self.assertLess(release.index("gitleaks git"), release.index("Provision temporary signing keychain"))
        self.assertLess(release.index("scripts/package-beta-dmg.sh --distribution"), release.index("Upload validated beta artifacts"))
        self.assertLess(release.index("Verify the packaged app from a read-only mount"), release.index("Upload validated beta artifacts"))
        upload = release.split("- name: Upload validated beta artifacts", 1)[1].split("- name:", 1)[0]
        self.assertNotIn("if:", upload)
        self.assertNotIn("continue-on-error", release)
        self.assertIn("if-no-files-found: error", upload)
        self.assertNotIn("runner.temp", upload)
        reports = release.split("- name: Upload secret scan reports", 1)[1].split("- name:", 1)[0]
        self.assertIn("if-no-files-found: error", reports)
        self.assertIn("${{ runner.temp }}/nav-center-current-secrets.json", reports)
        self.assertIn("${{ runner.temp }}/nav-center-history-secrets.json", reports)

    def test_build_stages_license_and_notices_into_resources(self):
        self.assert_ok(self.run_script("build-and-run.sh", "build"))
        resources = self.dist / "Nav Center.app/Contents/Resources"
        self.assertEqual((resources / "LICENSE").read_text(), (self.root / "LICENSE").read_text())
        self.assertEqual((resources / "THIRD_PARTY_NOTICES.md").read_text(), (self.root / "THIRD_PARTY_NOTICES.md").read_text())

    def test_build_fails_before_swift_when_license_or_notices_missing(self):
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            with self.subTest(name=name):
                target = self.root / name
                backup = target.read_text()
                target.unlink()
                result = self.run_script("build-and-run.sh", "build")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                self.assertEqual(self.events(), [])
                target.write_text(backup)
                self.trace.unlink(missing_ok=True)

    def test_local_package_places_license_and_notices_beside_app_in_image(self):
        notices = self.root / "THIRD_PARTY_NOTICES.md"
        notices.write_text(notices.read_text() + "License text: PENDING UPSTREAM CONFIRMATION\n")
        self.assert_ok(self.run_script("package-beta-dmg.sh", "--local"))
        created = [event for event in self.events() if event["tool"] == "hdiutil" and event["args"][0] == "create"]
        self.assertEqual(len(created), 1)
        for name in ("Nav Center.app", "Applications", "LICENSE", "THIRD_PARTY_NOTICES.md"):
            self.assertIn(name, created[0]["srcfolder"])

    def test_distribution_refuses_pending_notice_placeholder(self):
        (self.root / "THIRD_PARTY_NOTICES.md").write_text("License text: PENDING UPSTREAM CONFIRMATION\n")
        result = self.run_script("package-beta-dmg.sh", "--distribution", extra=self.credentials())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PENDING UPSTREAM CONFIRMATION", result.stderr)
        self.assertFalse(any(event["tool"] in ("swift", "codesign", "xcrun", "hdiutil") for event in self.events()))

    def test_workflow_mount_step_verifies_notices_and_version_strings(self):
        release = (REPO / ".github/workflows/beta-release.yml").read_text()
        marker = "- name: Verify the packaged app from a read-only mount"
        self.assertEqual(release.count(marker), 1)
        step = release.split(marker, 1)[1].split("\n      - name:", 1)[0]
        env, run = step.split("run:", 1)
        self.assertIn("scripts/verify-release-artifact.sh", run)
        self.assertIn("--expect-version", run)
        self.assertIn("--expect-build", run)
        self.assertIn('"$NAV_CENTER_VERSION"', run)
        self.assertIn('"$NAV_CENTER_BUILD"', run)
        self.assertIn("NAV_CENTER_VERSION: ${{ inputs.version }}", env)
        self.assertIn("NAV_CENTER_BUILD: ${{ inputs.build }}", env)
        self.assertNotIn("${{", run)
        self.assertLess(run.index("scripts/verify-release-artifact.sh"), run.index("shasum -a 256 -c"))

    def stage_mount(self, version="9.8.7-beta.2", build="42", short=None, nav=None, license_text="Synthetic license.\n", notices_text="Synthetic notices.\n"):
        mount = self.root / "mount-fixture"
        if mount.exists():
            shutil.rmtree(mount)
        contents = mount / "Nav Center.app" / "Contents"
        contents.mkdir(parents=True)
        payload = {
            "CFBundleShortVersionString": version.split("-", 1)[0] if short is None else short,
            "CFBundleVersion": build,
            "NavCenterVersion": version if nav is None else nav,
        }
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(payload, stream, fmt=plistlib.FMT_XML)
        if license_text is not None:
            (mount / "LICENSE").write_text(license_text)
        if notices_text is not None:
            (mount / "THIRD_PARTY_NOTICES.md").write_text(notices_text)
        return mount

    def stage_artifact(self, name="NavCenter-9.8.7-beta.2-macos-arm64.dmg", sidecar_name=None, status="Accepted", body=b"synthetic signed image"):
        image = self.root / name
        image.write_bytes(body)
        digest = hashlib.sha256(body).hexdigest()
        record = name if sidecar_name is None else sidecar_name
        Path(str(image) + ".sha256").write_text(f"{digest}  {record}\n")
        if status is not None:
            Path(str(image) + ".notary.json").write_text(json.dumps({"status": status}) + "\n")
        return image

    def run_verifier(self, image, *args, mount=None):
        self.trace.unlink(missing_ok=True)
        extra = {"FAKE_MOUNT_SOURCE": str(mount)} if mount is not None else None
        return self.run_script("verify-release-artifact.sh", str(image), *args, extra=extra)

    def test_verifier_passes_complete_artifact_and_checks_mounted_app(self):
        image = self.stage_artifact()
        mount = self.stage_mount()
        result = self.run_verifier(
            image, "--expect-version", "9.8.7-beta.2", "--expect-build", "42", mount=mount,
        )
        self.assert_ok(result)
        self.assertNotIn("\nFAIL ", "\n" + result.stdout)
        self.assertNotIn("\nMISSING ", "\n" + result.stdout)
        events = self.events()
        attach = [event for event in events if event["tool"] == "hdiutil" and event["args"][:1] == ["attach"]]
        self.assertEqual(len(attach), 1)
        self.assertIn("-readonly", attach[0]["args"])
        self.assertIn("-nobrowse", attach[0]["args"])
        mountpoint = attach[0]["args"][attach[0]["args"].index("-mountpoint") + 1]
        app = str(Path(mountpoint) / "Nav Center.app")
        deep = [
            event for event in events
            if event["tool"] == "codesign" and "--deep" in event["args"] and "--strict" in event["args"]
        ]
        self.assertEqual(len(deep), 1)
        self.assertEqual(deep[0]["args"][-1], app)
        execute = [
            event for event in events
            if event["tool"] == "spctl" and event["args"][event["args"].index("-t") + 1] == "execute"
        ]
        self.assertEqual(len(execute), 1)
        self.assertEqual(execute[0]["args"][-1], app)
        self.assertTrue(any(event["tool"] == "hdiutil" and event["args"][:1] == ["detach"] for event in events))
        self.assertFalse(Path(mountpoint).exists())

    def test_verifier_accepts_path_prefixed_sidecar_with_matching_basename(self):
        name = "NavCenter-0.1.0-beta-macos-arm64.dmg"
        image = self.stage_artifact(name=name, sidecar_name=f"dist/{name}")
        mount = self.stage_mount(version="0.1.0-beta", build="1")
        result = self.run_verifier(image, "--expect-version", "0.1.0-beta", "--expect-build", "1", mount=mount)
        self.assert_ok(result)
        self.assertIn("PASS checksum sidecar", result.stdout)

    def test_verifier_rejects_sidecar_naming_another_file(self):
        image = self.stage_artifact()
        mount = self.stage_mount()
        digest = hashlib.sha256(image.read_bytes()).hexdigest()
        sidecar = Path(str(image) + ".sha256")
        for record in ("other.dmg", "dist/other.dmg"):
            with self.subTest(record=record):
                sidecar.write_text(f"{digest}  {record}\n")
                result = self.run_verifier(
                    image, "--expect-version", "9.8.7-beta.2", "--expect-build", "42", mount=mount,
                )
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("FAIL checksum sidecar:", result.stdout)
                self.assertIn(record, result.stdout)

    def test_verifier_fails_when_notices_missing_from_image(self):
        image = self.stage_artifact()
        mount = self.stage_mount(license_text=None, notices_text=None)
        result = self.run_verifier(
            image, "--expect-version", "9.8.7-beta.2", "--expect-build", "42", mount=mount,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL LICENSE:", result.stdout)
        self.assertIn("FAIL THIRD_PARTY_NOTICES.md:", result.stdout)

    def test_verifier_fails_on_version_or_build_mismatch(self):
        image = self.stage_artifact()
        cases = (
            {"short": "1.2.3", "check": "CFBundleShortVersionString"},
            {"nav": "9.8.7-beta.9", "check": "NavCenterVersion"},
            {"build": "7", "check": "CFBundleVersion"},
        )
        for case in cases:
            with self.subTest(check=case["check"]):
                mount = self.stage_mount(
                    short=case.get("short"),
                    nav=case.get("nav"),
                    build=case.get("build", "42"),
                )
                result = self.run_verifier(
                    image, "--expect-version", "9.8.7-beta.2", "--expect-build", "42", mount=mount,
                )
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(f"FAIL {case['check']}:", result.stdout)

    def test_verifier_rejects_unsigned_name_before_tools_run(self):
        missing = self.run_verifier(self.root / "absent.dmg")
        self.assertEqual(missing.returncode, 66, missing.stdout + missing.stderr)
        usage = self.run_script("verify-release-artifact.sh")
        self.assertEqual(usage.returncode, 64, usage.stdout + usage.stderr)
        unsigned = self.root / "NavCenter-9.8.7-beta.2-macos-arm64-unsigned.dmg"
        unsigned.write_bytes(b"synthetic unsigned image")
        Path(str(unsigned) + ".sha256").write_text("ab" * 32 + "  " + unsigned.name + "\n")
        result = self.run_verifier(unsigned)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL name contract:", result.stdout)
        self.assertIn("unsigned", result.stdout)
        self.assertEqual(self.events(), [])

    def test_app_version_is_single_sourced(self):
        versions = json.loads((REPO / "scripts/tool-versions.json").read_text())
        app_version = versions["app_version"]
        plugin = json.loads((REPO / "plugins/nav-center/.codex-plugin/plugin.json").read_text())
        self.assertEqual(plugin["version"], app_version)
        version_default = re.compile(r'^VERSION="\$\{NAV_CENTER_VERSION:-([^}]+)\}"', re.MULTILINE)
        for script_name in ("scripts/build-and-run.sh", "scripts/package-beta-dmg.sh"):
            match = version_default.search((REPO / script_name).read_text())
            self.assertIsNotNone(match, script_name)
            self.assertEqual(match.group(1), app_version)
        changelog = (REPO / "CHANGELOG.md").read_text().splitlines()
        headings = [line for line in changelog if line.startswith("## ")]
        self.assertRegex(headings[0], rf"^## {re.escape(app_version)}(\s|$)")


class VendorNoticeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nav-center-vendor-notice-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write_snapshot(self, commit):
        vendor = self.root / "vendor/atsim"
        vendor.mkdir(parents=True)
        payload = b"synthetic snapshot\n"
        (vendor / "snapshot.txt").write_bytes(payload)
        manifest = {"snapshot.txt": hashlib.sha256(payload).hexdigest()}
        (vendor / "UPSTREAM-SHA256.json").write_text(json.dumps(manifest) + "\n")
        (vendor / "UPSTREAM.md").write_text(
            "- Repository: https://github.com/austinkennethtucker/cli\n"
            "- Source directory: `atsim/`\n"
            f"- Commit: `{commit}`\n"
            "- Copied: 2026-09-15\n"
            "- Package version: 0.1.0\n"
        )
        scripts = self.root / "scripts"
        scripts.mkdir(exist_ok=True)
        shutil.copy2(REPO / "scripts/verify-vendor.py", scripts / "verify-vendor.py")

    def run_verify(self, root=None):
        script_root = self.root if root is None else root
        return subprocess.run(
            [sys.executable, "-B", str(script_root / "scripts/verify-vendor.py")],
            cwd=script_root, capture_output=True, text=True,
        )

    def test_notices_reference_snapshot_commit_and_path(self):
        real = subprocess.run(
            [sys.executable, "-B", str(REPO / "scripts/verify-vendor.py")],
            cwd=REPO, capture_output=True, text=True,
        )
        self.assertEqual(real.returncode, 0, real.stderr + real.stdout)
        upstream = (REPO / "vendor/atsim/UPSTREAM.md").read_text()
        commit = re.search(r"(?m)^- Commit: `([0-9a-f]{40})`", upstream).group(1)
        notices = (REPO / "THIRD_PARTY_NOTICES.md").read_text()
        self.assertIn("vendor/atsim", notices)
        self.assertIn(commit, notices)
        self.assertNotIn("Copyright", notices.split("## @opencode-ai/sdk", 1)[0].split("## atsim", 1)[1])

        synthetic_commit = "0123456789abcdef0123456789abcdef01234567"
        self.write_snapshot(synthetic_commit)
        notice_path = self.root / "THIRD_PARTY_NOTICES.md"
        notice_path.write_text(f"vendor/atsim\n{synthetic_commit}\n")
        accepted = self.run_verify()
        self.assertEqual(accepted.returncode, 0, accepted.stderr + accepted.stdout)

        notice_path.write_text(f"{synthetic_commit}\n")
        missing_path = self.run_verify()
        self.assertNotEqual(missing_path.returncode, 0)
        self.assertIn("vendor/atsim", missing_path.stderr)

        notice_path.write_text("vendor/atsim\n")
        missing_commit = self.run_verify()
        self.assertNotEqual(missing_commit.returncode, 0)
        self.assertIn("upstream commit", missing_commit.stderr)

        notice_path.unlink()
        missing_file = self.run_verify()
        self.assertNotEqual(missing_file.returncode, 0)
        self.assertIn("THIRD_PARTY_NOTICES.md", missing_file.stderr)

    def test_verify_vendor_reports_pending_confirmation_without_failing(self):
        commit = "0123456789abcdef0123456789abcdef01234567"
        self.write_snapshot(commit)
        notices = self.root / "THIRD_PARTY_NOTICES.md"
        pending_line = "atsim notice is pending upstream confirmation and remains a distribution gate."
        notices.write_text(f"vendor/atsim\n{commit}\nLicense text: PENDING UPSTREAM CONFIRMATION\n")
        pending = self.run_verify()
        self.assertEqual(pending.returncode, 0, pending.stderr + pending.stdout)
        self.assertIn(pending_line, pending.stdout)

        notices.write_text(f"vendor/atsim\n{commit}\n")
        confirmed = self.run_verify()
        self.assertEqual(confirmed.returncode, 0, confirmed.stderr + confirmed.stdout)
        self.assertNotIn(pending_line, confirmed.stdout)
        self.assertNotIn("pending upstream confirmation", confirmed.stdout)


if __name__ == "__main__":
    unittest.main()
