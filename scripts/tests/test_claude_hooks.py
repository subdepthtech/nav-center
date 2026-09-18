"""Exercise repository hooks with synthetic paths and stubbed lint findings."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]


def load_hook(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / '.claude/hooks' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GUARD = load_hook('guard-protected-paths')
QUALITY = load_hook('swift-quality')


class ClaudeHookTests(unittest.TestCase):
    def test_guard_blocks_private_paths_and_vendor_alias_but_allows_review(self):
        with tempfile.TemporaryDirectory(prefix='nav-hook-test-') as temporary:
            root = Path(temporary).resolve()
            project = root / 'repo'
            vendor = project / 'vendor/atsim'
            vendor.mkdir(parents=True)
            alias = project / 'vendor-alias'
            alias.symlink_to(vendor, target_is_directory=True)
            home = root / 'synthetic-home'
            vault = root / 'synthetic-vault'

            def check(tool, target):
                payload = {'tool_name': tool, 'tool_input': {'file_path': str(target)}}
                with patch('sys.stdin', io.StringIO(json.dumps(payload))), contextlib.redirect_stderr(io.StringIO()):
                    try:
                        return GUARD.main()
                    except SystemExit as error:
                        return error.code

            with patch.dict(os.environ, {'CLAUDE_PROJECT_DIR': str(project), 'NAV_CENTER_VAULT_DIR': str(vault)}), patch.object(
                GUARD.os.path, 'expanduser', side_effect=lambda value: str(home) + value[1:] if value.startswith('~') else value
            ):
                self.assertEqual(check('Read', vendor / 'source.py'), 0)
                self.assertEqual(check('Write', vendor / 'source.py'), 2)
                self.assertEqual(check('Write', alias / 'source.py'), 2)
                self.assertEqual(check('Read', home / '.codex/auth.json'), 2)
                self.assertEqual(check('Read', home / 'Library/Application Support/Nav Center/Workspace/data'), 2)
                self.assertEqual(check('Read', vault / 'fixture'), 2)
                self.assertEqual(check('Write', project / 'Sources/fixture.swift'), 0)
                (project / '.claude').mkdir()
                (project / '.claude/ALLOW_VENDOR_SNAPSHOT_UPDATE').touch()
                self.assertEqual(check('Write', vendor / 'source.py'), 0)
                self.assertEqual(check('Read', vault / 'fixture'), 2)

    def test_quality_baseline_does_not_report_shifted_inherited_findings(self):
        finding = ('force_try', 'avoid force try')
        current = [(finding, 'fixture.swift:12'), (finding, 'fixture.swift:30')]
        previous = [(finding, 'fixture.swift:10')]
        with patch.object(QUALITY, 'baseline_copy', return_value='baseline.swift'):
            collect = lambda path, *_: previous if path == 'baseline.swift' else current
            self.assertEqual(QUALITY.regressions(collect, 'current.swift', 'Sources/fixture.swift', '.', '.', '.'), ['fixture.swift:12'])
            current.pop()
            self.assertEqual(QUALITY.regressions(collect, 'current.swift', 'Sources/fixture.swift', '.', '.', '.'), [])


if __name__ == '__main__':
    unittest.main()
