import collections
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]


class CommittedRangeWhitespaceTests(unittest.TestCase):
    def git(self, repository, *arguments, check=True):
        return subprocess.run(
            ["git", *arguments],
            cwd=repository,
            env=os.environ | {
                "GIT_CONFIG_NOSYSTEM": "1",
                "HOME": str(repository),
            },
            capture_output=True,
            text=True,
            check=check,
        )

    def test_workflows_use_remerge_diff_for_every_committed_range_check(self):
        ci = (REPO / ".github/workflows/ci.yml").read_text()
        release = (REPO / ".github/workflows/beta-release.yml").read_text()
        commands = lambda text: [
            line.strip() for line in text.splitlines()
            if line.strip().startswith("git log") and "--check" in line
        ]

        expected_ci = collections.Counter({
            'git log --format= --check --diff-merges=remerge "$merge_base..HEAD"': 2,
            'git log --format= --check --diff-merges=remerge "$PUSH_BEFORE_SHA..$tip"': 2,
            'git log -1 --format= --check --diff-merges=remerge "$tip"': 2,
            "git log -1 --format= --check --diff-merges=remerge HEAD": 2,
        })
        self.assertEqual(collections.Counter(commands(ci)), expected_ci)
        self.assertEqual(
            commands(release),
            ["git log -1 --format= --check --diff-merges=remerge HEAD"],
        )
        self.assertNotIn("git diff --check", ci + release)

    def test_remerge_diff_rejects_bad_resolution_and_accepts_clean_merge(self):
        with tempfile.TemporaryDirectory(prefix="nav-center-merge-check-") as temporary:
            repository = Path(temporary)
            self.git(repository, "init", "-q", "-b", "main")
            self.git(repository, "config", "user.name", "Synthetic Test")
            self.git(repository, "config", "user.email", "synthetic@example.invalid")
            fixture = repository / "fixture.txt"
            fixture.write_text("value=base\n")
            self.git(repository, "add", "fixture.txt")
            self.git(repository, "commit", "-qm", "base")
            base = self.git(repository, "rev-parse", "HEAD").stdout.strip()

            self.git(repository, "switch", "-qc", "left")
            fixture.write_text("value=left\n")
            self.git(repository, "commit", "-qam", "left")
            self.git(repository, "switch", "-q", "main")
            self.git(repository, "switch", "-qc", "right")
            fixture.write_text("value=right\n")
            self.git(repository, "commit", "-qam", "right")
            conflict = self.git(repository, "merge", "left", check=False)
            self.assertNotEqual(conflict.returncode, 0)

            fixture.write_text("value=resolved   \n")
            self.git(repository, "add", "fixture.txt")
            self.git(repository, "commit", "-qm", "merge with bad resolution")
            for parent in ("HEAD^1", "HEAD^2"):
                clean_parent = self.git(
                    repository, "log", "-1", "--format=", "--check", parent,
                    check=False,
                )
                self.assertEqual(clean_parent.returncode, 0, clean_parent.stdout + clean_parent.stderr)

            bare = self.git(
                repository, "log", "-1", "--format=", "--check", "HEAD",
                check=False,
            )
            self.assertEqual(bare.returncode, 0, bare.stdout + bare.stderr)
            bad_tip = self.git(
                repository, "log", "-1", "--format=", "--check",
                "--diff-merges=remerge", "HEAD", check=False,
            )
            self.assertNotEqual(bad_tip.returncode, 0)
            self.assertIn("trailing whitespace", bad_tip.stdout + bad_tip.stderr)
            bad_range = self.git(
                repository, "log", "--format=", "--check",
                "--diff-merges=remerge", f"{base}..HEAD", check=False,
            )
            self.assertNotEqual(bad_range.returncode, 0)

            fixture.write_text("value=resolved\n")
            self.git(repository, "add", "fixture.txt")
            self.git(repository, "commit", "--amend", "-qm", "merge with clean resolution")
            clean_tip = self.git(
                repository, "log", "-1", "--format=", "--check",
                "--diff-merges=remerge", "HEAD", check=False,
            )
            self.assertEqual(clean_tip.returncode, 0, clean_tip.stdout + clean_tip.stderr)
            clean_range = self.git(
                repository, "log", "--format=", "--check",
                "--diff-merges=remerge", f"{base}..HEAD", check=False,
            )
            self.assertEqual(clean_range.returncode, 0, clean_range.stdout + clean_range.stderr)


if __name__ == "__main__":
    unittest.main()
