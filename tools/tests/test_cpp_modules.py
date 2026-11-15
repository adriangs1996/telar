"""Verify rule 4 of the module checker: no `export import` but that of an own partition."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('check_cpp_modules', ROOT / 'tools/check-cpp-modules.py')
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class StrictReexports(unittest.TestCase):
    def test_reexports_another_module_even_when_the_interface_names_its_type(self):
        text = '''export module telar.runtime.editors.remote_editor;
export import telar.platform.process;
export namespace telar {
struct RemoteEditor { ProcessInspector inspector; };
}
'''

        self.assertEqual(checker.reexports_of(text), {'telar.platform.process'})

    def test_reexports_std(self):
        self.assertEqual(checker.reexports_of('export module a;\nexport import std;\n'), {'std'})

    def test_leaves_out_own_partitions_and_plain_imports(self):
        text = '''export module telar.git;
export import :config;
export  import  :checkout ;
import telar.base.memory;
import std;
'''

        self.assertEqual(checker.reexports_of(text), set())

    def test_reads_code_only(self):
        text = '''export module a;
// export import b;
/* export import c; */
inline constexpr auto text = "export import d;";
export
    import e;
'''

        self.assertEqual(checker.reexports_of(text), {'e'})

    def test_rejects_a_reexport_outside_the_allowlist(self):
        with self.assertRaisesRegex(RuntimeError, 'lib/a/a.cppm re-exports std; import it where'):
            checker.check_reexports({'lib/a/a.cppm': 'export module a;\nexport import std;\n'}, {})

    def test_rejects_an_allowlist_entry_that_no_longer_exists(self):
        with self.assertRaisesRegex(RuntimeError, 'lib/a/a.cppm no longer re-exports b; remove it'):
            checker.check_reexports({'lib/a/a.cppm': 'export module a;\nimport b;\n'}, {'lib/a/a.cppm': ['b']})

    def test_counts_the_allowlisted_reexports(self):
        sources = {
            'lib/a/a.cppm': 'export module a;\nexport import :p;\nexport import b;\nexport import std;\n',
            'src/gui/c/c.cppm': 'export module telar.gui.c;\nexport import telar.wire.vocabulary;\n',
        }
        allowed = {
            'lib/a/a.cppm': ['b', 'std'],
            'src/gui/c/c.cppm': ['telar.wire.vocabulary'],
        }

        self.assertEqual(checker.check_reexports(sources, allowed), 3)

    def test_leaves_tests_and_tools_out(self):
        sources = {
            'src/gui/tests/fixture/fixture.cppm': 'export module fixture;\nexport import telar.wire.vocabulary;\n',
            'src/runtime/tools/probe/probe.cppm': 'export module probe;\nexport import std;\n',
        }

        self.assertEqual(checker.check_reexports(sources, {}), 0)


if __name__ == '__main__':
    unittest.main()
