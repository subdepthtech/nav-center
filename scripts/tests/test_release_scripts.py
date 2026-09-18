"""Offline release regressions: all signing/notary/build processes are synthetic stubs."""
import hashlib
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

REPO = Path(__file__).resolve().parents[2]
STUB = r'''import json, os, pathlib, stat, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
event = name
if name == "xcrun": event += ":" + ":".join(args[:2])
if name == "spctl": event += ":" + args[args.index("-t") + 1]
if name == "codesign": event += ":verify" if "--verify" in args else ":sign"
if name == "gitleaks": event += ":" + args[0]
if name == "git": event += ":status" if "status" in args else ":rev-parse"
with open(os.environ["RELEASE_TRACE"], "a") as stream:
    stream.write(json.dumps({"tool": name, "args": args, "event": event}) + "\n")
if os.environ.get("FAIL_EVENT") == event: sys.exit(9)
if name == "git" and "--is-shallow-repository" in args: print(os.environ.get("RELEASE_SHALLOW", "false"))
if name == "git" and "status" in args and os.environ.get("RELEASE_DIRTY"): print(" M synthetic.swift")
if name == "swift" and "--show-bin-path" in args: print(os.environ["RELEASE_BIN"])
if name == "sips": pathlib.Path(args[args.index("--out") + 1]).write_bytes(b"synthetic PNG")
if name == "iconutil": pathlib.Path(args[args.index("-o") + 1]).write_bytes(b"synthetic ICNS")
if name == "lipo": print(os.environ.get("RELEASE_LIPO_ARCH", os.uname().machine))
if name == "hdiutil" and args[0] == "create": pathlib.Path(args[-1]).write_bytes(b"synthetic DMG")
if name == "xcrun" and args[:2] == ["notarytool", "submit"]:
    key = pathlib.Path(args[args.index("--key") + 1])
    assert stat.S_IMODE(key.stat().st_mode) == 0o600
    assert "APP_STORE_CONNECT_PRIVATE_KEY" not in os.environ
    print(json.dumps({"id": "synthetic-id", "status": os.environ.get("NOTARY_STATUS", "Accepted")}))
if name == "xcrun" and args[:2] == ["stapler", "staple"]:
    with open(args[2], "ab") as stream: stream.write(b"synthetic ticket")
'''


class ReleaseScriptsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nav-center-release-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "Resources").mkdir()
        (self.root / "Resources/AppIcon.png").write_bytes(b"synthetic icon source")
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

    def test_cask_guards_each_supported_architecture(self):
        for architecture in ("arm64", "x86_64"):
            path = self.root / f"{architecture}.rb"
            url = f"https://example.org/NavCenter-9.8.7-beta.2-macos-{architecture}.dmg"
            self.assert_ok(self.run_script("update-homebrew-cask.sh", "9.8.7-beta.2", url, "a" * 64, architecture, str(path)))
            self.assertIn(f"depends_on arch: :{architecture}", path.read_text())
            syntax = subprocess.run(["/usr/bin/ruby", "-c", str(path)], capture_output=True, text=True)
            self.assert_ok(syntax)
        self.assertEqual(self.events(), [])

    def test_cask_rejects_mismatched_or_unsigned_assets_before_writing(self):
        path = self.root / "invalid.rb"
        for url in ("https://example.org/NavCenter-9.8.7-beta.2-macos-x86_64.dmg",
                    "https://example.org/NavCenter-9.8.7-beta.2-macos-arm64-unsigned.dmg",
                    'https://example.org/"#{system("false")}/NavCenter-9.8.7-beta.2-macos-arm64.dmg'):
            result = self.run_script("update-homebrew-cask.sh", "9.8.7-beta.2", url, "a" * 64, "arm64", str(path))
            self.assertNotEqual(result.returncode, 0)
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


if __name__ == "__main__":
    unittest.main()
