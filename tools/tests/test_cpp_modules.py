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
        # Every module declares telar, as telar.base.color does here.
        interfaces = {**self.interfaces, 'lib/base/color/color.cppm': COLOR}
        uses = {
            'src/gui/view/view.cpp': unit('using namespace telar::layout;\n', 'telar.base.geometry'),
            'src/gui/view/alias.cpp': unit('namespace shapes = telar::layout;\n', 'telar.base.geometry'),
            'src/gui/view/qualified.cpp': unit('namespace telar { int x = telar::other; }\n', 'telar.base.geometry'),
        }

        self.assertEqual(sites(uses, interfaces), {'src/gui/view/qualified.cpp': {'telar.base.geometry'}})

    def test_a_qualifier_counts_when_only_that_module_declares_the_namespace(self):
        cells = ('telar.runtime.terminal.grid', 'export module telar.runtime.terminal.grid;\n'
                 'export namespace telar::runtime::cell_layout {\n#include "cell_layout.inc"\n}\n')
        control = ('telar.runtime.terminal.control', 'export module telar.runtime.terminal.control;\n'
                   'export namespace telar::runtime { struct Parameters {}; }\n')
        interfaces = {'src/runtime/terminal/grid/grid.cppm': cells, 'src/runtime/terminal/control/control.cppm': control}
        units = {
            'src/gui/view/view.cpp': unit('auto wide = telar::runtime::cell_layout::wide(0);\n', 'telar.runtime.terminal.grid'),
            'src/gui/view/runtime.cpp': unit('auto value = telar::runtime::other;\n', 'telar.runtime.terminal.control'),
            'src/gui/view/local.cpp': unit('int cell_layout = 0;\n', 'telar.runtime.terminal.grid'),
        }

        self.assertEqual(sites(units, interfaces), {
            'src/gui/view/runtime.cpp': {'telar.runtime.terminal.control'},
            'src/gui/view/local.cpp': {'telar.runtime.terminal.grid'},
        })

    def test_the_items_of_an_exported_x_macro_list_are_names_of_the_module(self):
        signals = ('telar.sys.process', '''module;
#include <signal.h>
export module telar.sys.process;

#define SIGNALS(X) \\
  X(SIGINT)        \\
  X(SIGTERM)
#define WAITS(X) \\
  X(WNOHANG)     \\
  SIGNALS(X)
#define CONSTANT(name) inline constexpr auto name = captured::name##_;

export {
  SIGNALS(CONSTANT)
  WAITS(CONSTANT)
}
''')
        interfaces = {'lib/sys/process/process.cppm': signals}
        for body in ('int signal = SIGTERM;', 'int flags = WNOHANG;'):
            with self.subTest(body=body):
                self.assertEqual(sites({'src/gui/view/view.cpp': unit(body, 'telar.sys.process')}, interfaces), {})
        for body in ('int signal = SIGNALS;', 'int value = name;'):
            with self.subTest(body=body):
                self.assertEqual(sites({'src/gui/view/view.cpp': unit(body, 'telar.sys.process')}, interfaces),
                                 {'src/gui/view/view.cpp': {'telar.sys.process'}})

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


LAYERS = {'runtime': ['platform', 'terminal', 'http', 'proxy', 'tests']}


def domain_files(deps='', sources='', extra=None):
    """A proxy domain over the terminal and platform domains: its interface imports terminal,
    its implementation unit platform."""
    files = {
        'src/runtime/proxy/CMakeLists.txt': f'# The proxy.\ntelar_add_domain(runtime proxy\n  SOURCES {sources or "relay/relay.cpp"}\n  DEPS {deps} telar::config)\n',
        'src/runtime/proxy/relay/relay.cppm': 'export module telar.runtime.proxy.relay;\nimport telar.runtime.terminal.grid;\nimport telar.config;\n',
        'src/runtime/proxy/relay/relay.cpp': 'module telar.runtime.proxy.relay;\nimport telar.runtime.platform.socket;\n',
        'src/runtime/proxy/tests/probe.cppm': 'export module probe;\nimport telar.runtime.http.message;\n',
    }
    files.update(extra or {})
    return files


def check_domains(files):
    return checker.check_domain_targets(LAYERS, set(files), files.__getitem__)


class DomainTargets(unittest.TestCase):
    def test_accepts_deps_that_match_the_imports(self):
        self.assertEqual(check_domains(domain_files('platform terminal')), 1)

    def test_rejects_a_dependency_above_the_domain(self):
        with self.assertRaisesRegex(RuntimeError, r'telar_add_domain\(runtime http\) depends on proxy, which is not below http'):
            check_domains(domain_files('platform terminal', extra={
                'src/runtime/http/CMakeLists.txt': 'telar_add_domain(runtime http DEPS proxy)\n',
                'src/runtime/http/message/message.cppm': 'export module telar.runtime.http.message;\nimport telar.runtime.proxy.relay;\n',
            }))

    def test_rejects_an_imported_domain_missing_from_deps(self):
        with self.assertRaisesRegex(RuntimeError, r'telar_add_domain\(runtime proxy\) does not depend on platform, but '
                                    'src/runtime/proxy/relay/relay.cpp imports telar.runtime.platform.socket'):
            check_domains(domain_files('terminal'))

    def test_rejects_a_dependency_no_file_imports(self):
        with self.assertRaisesRegex(RuntimeError, 'depends on http, which none of its files imports'):
            check_domains(domain_files('platform terminal http'))

    def test_reads_only_the_sources_the_domain_lists(self):
        # Without relay.cpp in SOURCES, its import of platform is another target's concern.
        files = domain_files('terminal', sources='MACOS_SOURCES relay/macos/relay.mm')
        files['src/runtime/proxy/relay/macos/relay.mm'] = '#include <Foundation/Foundation.h>\n'
        self.assertEqual(check_domains(files), 1)

    def test_rejects_a_domain_outside_its_folder_or_the_layers(self):
        with self.assertRaisesRegex(RuntimeError, 'belongs in src/runtime/proxy/CMakeLists.txt'):
            check_domains({'src/runtime/CMakeLists.txt': 'telar_add_domain(runtime proxy)\n'})
        with self.assertRaisesRegex(RuntimeError, 'names no domain of process_layers'):
            check_domains({'src/runtime/tests/CMakeLists.txt': 'telar_add_domain(runtime tests)\n'})
        with self.assertRaisesRegex(RuntimeError, 'depends on cache, which is no domain of runtime'):
            check_domains(domain_files('platform terminal cache'))


NESTED_LAYERS = {'gui': ['core', 'foundation/text', 'features/terminal/screen', 'features/terminal/links', 'tests']}


def nested_files(deps='foundation/text features/terminal/screen', exclude='EXCLUDE screen'):
    """A links feature nested below the terminal group: its interface imports a foundation module
    and a sibling feature, and the terminal group folder holds the screen feature below it."""
    return {
        'src/gui/features/terminal/links/CMakeLists.txt': f'telar_add_domain(gui features/terminal/links\n  DEPS {deps})\n',
        'src/gui/features/terminal/links/links.cppm': 'export module telar.gui.features.terminal.links;\n'
                                                       'import telar.gui.foundation.text;\nimport telar.gui.features.terminal.screen;\n',
        'src/gui/features/terminal/screen/CMakeLists.txt': f'telar_add_domain(gui features/terminal/screen\n  DEPS foundation/text)\n',
        'src/gui/features/terminal/screen/screen.cppm': 'export module telar.gui.features.terminal.screen;\nimport telar.gui.foundation.text;\n',
    }


class NestedDomains(unittest.TestCase):
    def test_a_module_belongs_to_the_longest_domain_that_holds_it(self):
        self.assertEqual(checker.component('telar.gui.features.terminal.links', NESTED_LAYERS), 'gui/features/terminal/links')
        self.assertEqual(checker.component('telar.gui.features.terminal.links:hover', NESTED_LAYERS), 'gui/features/terminal/links')
        self.assertEqual(checker.component('telar.gui.core.metrics', NESTED_LAYERS), 'gui/core')
        self.assertEqual(checker.component('telar.base.memory', NESTED_LAYERS), 'lib/base')

    def test_accepts_nested_deps_that_match_the_imports(self):
        files = nested_files()
        self.assertEqual(checker.check_domain_targets(NESTED_LAYERS, set(files), files.__getitem__), 2)

    def test_rejects_a_nested_dependency_above_the_domain(self):
        files = nested_files()
        files['src/gui/features/terminal/screen/CMakeLists.txt'] = 'telar_add_domain(gui features/terminal/screen\n  DEPS features/terminal/links)\n'
        files['src/gui/features/terminal/screen/screen.cppm'] = 'export module telar.gui.features.terminal.screen;\nimport telar.gui.features.terminal.links;\n'
        with self.assertRaisesRegex(RuntimeError, r'depends on features/terminal/links, which is not below features/terminal/screen'):
            checker.check_domain_targets(NESTED_LAYERS, set(files), files.__getitem__)

    def test_a_domain_leaves_out_the_domains_it_excludes(self):
        files = nested_files()
        files['src/gui/features/terminal/CMakeLists.txt'] = 'telar_add_domain(gui features/terminal\n  EXCLUDE links screen)\n'
        layers = {'gui': ['foundation/text', 'features/terminal', 'features/terminal/screen', 'features/terminal/links', 'tests']}
        files['src/gui/features/terminal/terminal.cppm'] = 'export module telar.gui.features.terminal;\n'
        self.assertEqual(checker.check_domain_targets(layers, set(files), files.__getitem__), 3)


ROOTS = ['src/gui/features', 'src/gui/foundation']


def namespaces(files):
    return checker.check_module_namespaces(set(files), ROOTS, files.__getitem__)


class ModuleNamespaces(unittest.TestCase):
    def test_accepts_exports_into_the_namespace_of_the_name_or_below_it(self):
        self.assertEqual(namespaces({
            'src/gui/features/history/history.cppm': 'export module telar.gui.features.history;\n'
                                                     'export namespace telar::gui::features::history {\n  struct Query {};\n}\n'
                                                     'export {\n  namespace telar::gui::features::history::detail {\n    int depth();\n  }\n}\n',
            'src/gui/features/history/history-browser.cppm': 'export module telar.gui.features.history:browser;\n'
                                                             'export namespace telar::gui::features::history {\n  struct Page {};\n}\n',
        }), 2)

    def test_rejects_an_export_outside_it(self):
        with self.assertRaisesRegex(RuntimeError, r'exports into telar::gui; telar.gui.features.history exports into telar::gui::features::history'):
            namespaces({'src/gui/features/history/history.cppm': 'export module telar.gui.features.history;\n'
                                                                 'export namespace telar::gui {\n  struct Query {};\n}\n'})

    def test_ignores_modules_outside_the_roots_and_unexported_declarations(self):
        self.assertEqual(namespaces({
            'src/gui/core/metrics/metrics.cppm': 'export module telar.gui.core.metrics;\nexport namespace telar::gui {\n  struct Rect {};\n}\n',
            'src/gui/features/peek/peek.cppm': 'export module telar.gui.features.peek;\nnamespace telar::gui::detail {\n  int hidden();\n}\n'
                                               'export namespace telar::gui::features::peek {\n  int open();\n}\n',
        }), 1)


LIBRARY_LAYERS = {'sys': [], 'base': ['sys'], 'tls': ['base'], 'testing': ['sys']}


def placed(extra):
    """The proxy domain over terminal and platform, with the tests of `extra`."""
    files = {
        'src/runtime/platform/CMakeLists.txt': 'telar_add_domain(runtime platform)\n',
        'src/runtime/terminal/CMakeLists.txt': 'telar_add_domain(runtime terminal DEPS platform)\n',
        'src/runtime/http/CMakeLists.txt': 'telar_add_domain(runtime http)\n',
        'src/runtime/proxy/CMakeLists.txt': 'telar_add_domain(runtime proxy\n  DEPS terminal telar::config)\n',
    }
    files.update(extra)
    return checker.check_test_placement(LAYERS, LIBRARY_LAYERS, set(files), files.__getitem__)


def test_unit(*imports):
    return ''.join(f'import {name};\n' for name in ('telar.testing', *imports))


class TestPlacement(unittest.TestCase):
    def test_accepts_a_domain_test_of_the_domain_and_what_it_builds_on(self):
        self.assertEqual(placed({
            'src/runtime/proxy/tests/relay_test.cpp': test_unit('telar.runtime.proxy.relay', 'telar.runtime.platform.socket', 'telar.base.text'),
            'src/runtime/proxy/tests/peer/peer.cppm': 'export module telar.runtime.proxy.tests.peer;\n' + test_unit('telar.runtime.terminal.grid'),
        }), 2)

    def test_rejects_a_domain_test_that_reaches_a_domain_its_domain_does_not_build_on(self):
        with self.assertRaisesRegex(RuntimeError, 'relay_test.cpp imports the http domain, which proxy does not build on: '
                                    'as an integration test it belongs in src/runtime/tests/'):
            placed({'src/runtime/proxy/tests/relay_test.cpp': test_unit('telar.runtime.proxy.relay', 'telar.runtime.http.message')})

    def test_accepts_an_integration_test_no_single_domain_holds(self):
        self.assertEqual(placed({
            'src/runtime/tests/flow_test.cpp': test_unit('telar.runtime.proxy.relay', 'telar.runtime.http.message'),
        }), 1)

    def test_rejects_an_integration_test_one_domain_holds(self):
        with self.assertRaisesRegex(RuntimeError, 'flow_test.cpp reaches only proxy and what it builds on: '
                                    'it belongs in src/runtime/proxy/tests/'):
            placed({'src/runtime/tests/flow_test.cpp': test_unit('telar.runtime.proxy.relay', 'telar.runtime.platform.socket')})
        with self.assertRaisesRegex(RuntimeError, 'imports no domain of runtime: it belongs with the library it checks'):
            placed({'src/runtime/tests/text_test.cpp': test_unit('telar.base.text')})

    def test_a_library_test_imports_what_the_library_builds_on(self):
        self.assertEqual(placed({'lib/tls/tests/tls_test.cpp': test_unit('telar.tls', 'telar.base.text', 'telar.sys.posix')}), 1)
        # A sibling the library does not build on lends its utilities.
        self.assertEqual(placed({'lib/tls/tests/tls_test.cpp': test_unit('telar.tls', 'telar.testing.socket_pair', 'telar.platform.fs')}), 1)
        with self.assertRaisesRegex(RuntimeError, 'tls_test.cpp imports telar.runtime.proxy.relay, which is no library'):
            placed({'lib/tls/tests/tls_test.cpp': test_unit('telar.tls', 'telar.runtime.proxy.relay')})
        with self.assertRaisesRegex(RuntimeError, 'base_test.cpp imports telar.tls, but lib/tls builds on lib/base'):
            placed({'lib/base/tests/base_test.cpp': test_unit('telar.base.text', 'telar.tls')})

    def test_rejects_a_test_outside_a_tests_folder(self):
        with self.assertRaisesRegex(RuntimeError, 'src/runtime/proxy/relay_test.cpp is a test outside a tests/ folder'):
            placed({'src/runtime/proxy/relay_test.cpp': test_unit('telar.runtime.proxy.relay')})

    def test_leaves_the_gui_and_tbc_to_their_own_layout(self):
        self.assertEqual(placed({
            'src/gui/tests/view_test.cpp': test_unit('telar.gui.core.metrics'),
            'lib/tbc/tests/spec/places.cpp': 'import telar.runtime.proxy.relay;\n',
        }), 0)


if __name__ == '__main__':
    unittest.main()
