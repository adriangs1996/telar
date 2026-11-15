"""Verify rules 4 and 6 of the module checker: no `export import` but that of an own partition,
and no import a unit does not use."""
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

    def test_applies_to_tests_and_tools(self):
        sources = {
            'src/gui/tests/fixture/fixture.cppm': 'export module fixture;\nexport import telar.wire.vocabulary;\n',
            'src/runtime/tools/probe/probe.cppm': 'export module probe;\nexport import std;\n',
        }

        with self.assertRaisesRegex(RuntimeError, 'src/gui/tests/fixture/fixture.cppm re-exports telar.wire.vocabulary'):
            checker.check_reexports(sources, {})
        with self.assertRaisesRegex(RuntimeError, 'src/runtime/tools/probe/probe.cppm re-exports std'):
            checker.check_reexports(sources, {})


GEOMETRY = (
    'telar.base.geometry',
    '''module;
#include "telar_base/geometry.hpp"

export module telar.base.geometry;

import std;

export namespace telar {
  struct Size { int width; int height; };
  template <typename Value>
  concept Measurable = requires(Value value) { value.width; };
  inline constexpr int default_width = 80;
  enum Corner { top_left, bottom_right };
  inline int area(Size size) noexcept { int local = size.width; return local * size.height; }
  namespace layout {}
}

namespace telar {
  inline int hidden() { return 0; }
}
''',
)
COLOR = ('telar.base.color', 'export module telar.base.color;\nexport namespace telar { struct Color {}; }\n')
THEME = ('telar.gui.theme', 'export module telar.gui.theme;\nexport import telar.base.color;\nexport namespace telar::gui { struct Theme {}; }\n')


def sites(units, interfaces, reexports=None, implicit=()):
    """The unused imports of `units`, with `interfaces` mapping each interface file to its module
    and text."""
    sources = {path: text for path, (_, text) in interfaces.items()}
    modules = {path: module for path, (module, _) in interfaces.items()}
    provided = checker.provided_names(sources, modules, reexports or {}, list(implicit))

    return checker.unused_import_sites({path: text.encode() for path, text in units.items()}, provided)


def unit(body, *imports):
    return 'module telar.gui.view;\n\n' + ''.join(f'import {name};\n' for name in imports) + '\n' + body


class UnusedImports(unittest.TestCase):
    interfaces = {'lib/base/geometry/geometry.cppm': GEOMETRY}

    def test_naming_a_type_uses_the_import(self):
        units = {
            'src/gui/view/view.cpp': unit('telar::Size size{};\n', 'telar.base.geometry'),
            'src/gui/view/idle.cpp': unit('int idle = 0;\n', 'telar.base.geometry'),
        }

        self.assertEqual(sites(units, self.interfaces), {'src/gui/view/idle.cpp': {'telar.base.geometry'}})

    def test_naming_a_function_variable_concept_or_enumerator_uses_the_import(self):
        for body in ('return telar::area({});', 'int width = telar::default_width;',
                     'template <telar::Measurable T> void f(T);', 'auto corner = telar::top_left;'):
            with self.subTest(body=body):
                self.assertEqual(sites({'src/gui/view/view.cpp': unit(body, 'telar.base.geometry')}, self.interfaces), {})

    def test_members_locals_and_unexported_names_do_not_use_it(self):
        for body in ('int width = size.width;', 'int local = 0;', 'int value = hidden();', 'Value value;'):
            with self.subTest(body=body):
                self.assertEqual(sites({'src/gui/view/view.cpp': unit(body, 'telar.base.geometry')}, self.interfaces),
                                 {'src/gui/view/view.cpp': {'telar.base.geometry'}})

    def test_a_namespace_counts_when_named_by_itself_not_as_a_qualifier(self):
        uses = {
            'src/gui/view/view.cpp': unit('using namespace telar::layout;\n', 'telar.base.geometry'),
            'src/gui/view/alias.cpp': unit('namespace shapes = telar::layout;\n', 'telar.base.geometry'),
            'src/gui/view/qualified.cpp': unit('namespace telar { int x = telar::other; }\n', 'telar.base.geometry'),
        }

        self.assertEqual(sites(uses, self.interfaces), {'src/gui/view/qualified.cpp': {'telar.base.geometry'}})

    def test_a_name_that_reaches_the_module_through_a_listed_reexport_uses_it(self):
        interfaces = {'lib/base/color/color.cppm': COLOR, 'src/gui/theme/theme.cppm': THEME}
        reexports = {'src/gui/theme/theme.cppm': ['telar.base.color']}
        units = {'src/gui/view/view.cpp': unit('telar::Color color;\n', 'telar.gui.theme')}

        self.assertEqual(sites(units, interfaces, reexports), {})
        self.assertEqual(sites(units, interfaces, {}), {'src/gui/view/view.cpp': {'telar.gui.theme'}})

    def test_comments_and_literals_name_nothing(self):
        body = '''// telar::Size
/* area(size) */
auto text = "Size";
auto raw = R"x(default_width)x";
auto letter = 'a';
'''

        self.assertEqual(sites({'src/gui/view/view.cpp': unit(body, 'telar.base.geometry')}, self.interfaces),
                         {'src/gui/view/view.cpp': {'telar.base.geometry'}})

    def test_the_import_line_names_nothing(self):
        interfaces = {'lib/base/area/area.cppm': ('telar.base.area', 'export module telar.base.area;\nexport int area();\n')}

        self.assertEqual(sites({'src/gui/view/view.cpp': unit('int x;\n', 'telar.base.area')}, interfaces),
                         {'src/gui/view/view.cpp': {'telar.base.area'}})

    def test_leaves_out_std_reexports_and_unknown_modules(self):
        text = 'export module telar.gui.view;\nimport std;\nexport import telar.base.geometry;\nimport telar.elsewhere;\n'

        self.assertEqual(sites({'src/gui/view/view.cppm': text}, self.interfaces), {})

    def test_a_partition_provides_what_it_declares(self):
        interfaces = {'src/gui/view/view-cells.cppm': ('telar.gui.view:cells', 'export module telar.gui.view:cells;\nstruct Cell {};\n')}
        units = {
            'src/gui/view/view.cpp': unit('Cell cell;\n', ':cells'),
            'src/gui/view/idle.cpp': unit('int idle;\n', ':cells'),
        }

        self.assertEqual(sites(units, interfaces), {'src/gui/view/idle.cpp': {':cells'}})

    def test_a_declared_implicit_use_counts_when_the_unit_names_its_type(self):
        formatting = ('telar.base.formatting', 'export module telar.base.formatting;\n'
                      'export template <> struct std::formatter<telar::Size> {};\n')
        interfaces = {**self.interfaces, 'lib/base/formatting/formatting.cppm': formatting}
        implicit = [{'module': 'telar.base.formatting', 'names': ['Size'], 'reason': 'std::formatter<Size>'}]
        units = {'src/gui/view/view.cpp': unit('auto text = std::format("{}", telar::Size{});\n',
                                               'telar.base.geometry', 'telar.base.formatting')}

        self.assertEqual(sites(units, interfaces), {'src/gui/view/view.cpp': {'telar.base.formatting'}})
        self.assertEqual(sites(units, interfaces, implicit=implicit), {})
        with self.assertRaisesRegex(RuntimeError, 'needs a known module, the names it applies to and a reason'):
            sites(units, interfaces, implicit=[{'module': 'telar.base.formatting', 'names': ['Size']}])

    def test_rejects_an_unused_import_missing_from_the_allowlist(self):
        units = {'src/gui/view/idle.cpp': unit('int idle;\n', 'telar.base.geometry').encode()}
        provided = checker.provided_names({'g': GEOMETRY[1]}, {'g': GEOMETRY[0]}, {}, [])

        with self.assertRaisesRegex(RuntimeError, 'src/gui/view/idle.cpp imports telar.base.geometry but names nothing'):
            checker.check_unused_imports(units, provided, {})
        self.assertEqual(checker.check_unused_imports(units, provided, {'src/gui/view/idle.cpp': ['telar.base.geometry']}), 1)

    def test_rejects_an_allowlist_entry_left_over(self):
        units = {'src/gui/view/view.cpp': unit('telar::Size size;\n', 'telar.base.geometry').encode()}
        provided = checker.provided_names({'g': GEOMETRY[1]}, {'g': GEOMETRY[0]}, {}, [])

        with self.assertRaisesRegex(RuntimeError, 'src/gui/view/view.cpp no longer has an unused import of telar.base.geometry'):
            checker.check_unused_imports(units, provided, {'src/gui/view/view.cpp': ['telar.base.geometry']})


if __name__ == '__main__':
    unittest.main()
