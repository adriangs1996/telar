"""Exercise the EBNF format entry point without invoking a real formatter."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CMAKE = str(ROOT / '.toolchain/bin/cmake') if (ROOT / '.toolchain/bin/cmake').exists() else shutil.which('cmake')


@unittest.skipUnless(CMAKE, 'requires CMake; never bootstraps tools from a test')
class ModuleFormatting(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='telar-format-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'project'
        self.binary = self.source / 'private-cache'
        self.tool = self.root / 'bin'
        self.tool.mkdir()
        self.log = self.root / 'formatter.json'
        self.files = ['main.cpp', 'api.cppm', 'nested/part.cppm']
        self.excluded = ['vendor/vendor.cppm', 'out-release/output.cppm',
                         'build-cache/cache.cppm', 'generated/table.cppm', 'private-cache/cache.cppm']
        for name in [*self.files, *self.excluded]:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('unformatted\n')
        formatter = self.tool / 'clang-format'
        formatter.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
Path(os.environ['FORMAT_LOG']).write_text(json.dumps(args))
modules = [Path(arg) for arg in args if arg.endswith('.cppm')]
if '--dry-run' in args and modules:
    print('rejected module formatting')
    sys.exit(7)
if '-i' in args:
    for module in modules:
        module.write_text('formatted module\\n')
''')
        formatter.chmod(0o755)

    def invoke(self, mode):
        return subprocess.run([CMAKE, '-DMODE=' + mode, '-DSOURCE_DIR=' + str(self.source),
                               '-DBINARY_DIR=' + str(self.binary), '-DCOMPILER_DIR=' + str(self.tool),
                               '-P', str(ROOT / 'lib/ebnf/cmake/tooling.cmake')],
                              env=dict(os.environ, FORMAT_LOG=str(self.log)), text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def assert_selection(self):
        arguments = json.loads(self.log.read_text())
        files = {Path(arg).relative_to(self.source).as_posix() for arg in arguments
                 if arg.endswith(('.cpp', '.cppm'))}
        self.assertEqual(files, set(self.files))
        for name in self.excluded:
            self.assertEqual((self.source / name).read_text(), 'unformatted\n')
        return arguments

    def test_format_edits_module_interfaces_and_preserves_exclusions(self):
        result = self.invoke('format')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('-i', self.assert_selection())
        self.assertEqual((self.source / 'api.cppm').read_text(), 'formatted module\n')
        self.assertEqual((self.source / 'nested/part.cppm').read_text(), 'formatted module\n')

    def test_format_check_reports_module_errors_without_editing(self):
        result = self.invoke('format-check')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('rejected module formatting', result.stdout)
        arguments = self.assert_selection()
        self.assertIn('--dry-run', arguments)
        self.assertIn('--Werror', arguments)
        self.assertEqual((self.source / 'api.cppm').read_text(), 'unformatted\n')


if __name__ == '__main__':
    unittest.main()
