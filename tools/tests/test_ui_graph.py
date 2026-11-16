"""Verify the folder graph of src/gui/ui that tools/ui-graph.py reads from git, and its rules."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('ui_graph', ROOT / 'tools/ui-graph.py')
graph = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(graph)

UI = 'src/gui/ui/'


def include(header):
    return f'#include "ui/{header}"\n'


def registered(name, macro=None):
    """A header that registers the class `name` for QML, by default under its own name."""
    return f'class {name} : public QObject {{\n    {macro or f"QML_NAMED_ELEMENT({name})"}\n}};\n'


class UiGraph(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='telar-ui-graph-')
        self.addCleanup(temporary.cleanup)
        self.repository = Path(temporary.name)
        self.git('init', '-q')

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repository, check=True, text=True,
                              stdout=subprocess.PIPE).stdout.strip()

    def tree(self, files):
        """Write `files` below ui/ and return the id of a git tree that holds them."""
        for name, text in files.items():
            path = self.repository / UI / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

        self.git('add', '-A')
        return self.git('write-tree')

    def run_report(self, files, verbose=False, rules=False):
        rev = self.tree(files)
        lines, code = graph.report(rev, graph.load_sources(rev, self.repository), verbose, rules)
        return lines[1:], code

    def test_a_node_is_a_directory_at_any_depth(self):
        rev = self.tree({
            'main.cpp': include('app/chrome/activity/agent_card.hpp'),
            'app/application_controller.hpp': include('app/chrome/sidebar.hpp'),
            'app/chrome/sidebar.hpp': include('app/chrome/activity/agent_card.hpp'),
            'app/chrome/activity/agent_card.hpp': include('app/chrome/activity/agent_row.hpp'),
            'app/chrome/activity/agent_row.hpp': '',
            'app/chrome/README.md': include('foundation/models/projection.hpp'),
        })

        sources = graph.load_sources(rev, self.repository)

        self.assertNotIn(UI + 'main.cpp', sources)
        self.assertNotIn(UI + 'app/chrome/README.md', sources)
        self.assertEqual(graph.include_edges(sources), [
            (UI + 'app/application_controller.hpp', 'app', 'app/chrome', 'sidebar.hpp'),
            (UI + 'app/chrome/sidebar.hpp', 'app/chrome', 'app/chrome/activity', 'agent_card.hpp'),
        ])

    def test_counts_root_users_shared_headers_and_cycles(self):
        lines, code = self.run_report({
            'app/application_controller.hpp': include('chrome/sidebar.hpp') + include('app/projection.hpp'),
            'app/projection.hpp': '',
            'app/runtime_connection.hpp': '',
            'chrome/sidebar.hpp': include('app/application_controller.hpp') + include('app/projection.hpp'),
            'chrome/sidebar.cpp': include('chrome/sidebar.hpp') + include('app/runtime_connection.hpp'),
            'panes/pane.hpp': include('app/projection.hpp') + include('chrome/sidebar.hpp'),
        }, verbose=True)

        self.assertEqual(code, 0)
        self.assertEqual(lines, [
            "root header includers outside app: 1 files in 1 folders: ['chrome']",
            "shared app headers used from outside: {'projection.hpp': 2}",
            "C++ as is edges 4 cycles: [(2, ['app', 'chrome'])]",
            "C++ shared->foundation edges 5 cycles: [(2, ['app', 'chrome'])]",
            'C++ shared out + no root edges edges 4 cycles: []',
            'QML edges 0 cycles: []',
            "   app -> ['chrome']",
            "   chrome -> ['foundation']",
            "   panes -> ['chrome', 'foundation']",
            'root users:',
            '   src/gui/ui/chrome/sidebar.hpp',
            'QML edges:',
        ])

    def test_qml_edges_follow_instantiated_types(self):
        lines, _ = self.run_report({
            'activity/AgentCard.qml': 'Item {\n    ElementHost {}\n}\n',
            'components/ElementHost.qml': 'Item {\n    BarPill { }\n    Sidebar\n}\n',
            'design/BarPill.qml': 'Rectangle {}\n',
            'chrome/Sidebar.qml': 'Item { ActivityList{} }\n',
            'activity/ActivityList.qml': 'ListView { AgentCard {} }\n',
        })

        self.assertEqual(lines[-1], "QML edges 3 cycles: []")

    def test_qml_edges_follow_relative_imports(self):
        rev = self.tree({
            'app/chrome/StatusBar.qml': 'import QtQuick\nimport "../../components/Fit.js" as Fit\nItem {}\n',
            'app/chrome/Sidebar.qml': 'import "Local.js" as Local\nimport "activity"\nItem {}\n',
            'app/chrome/Local.js': '',
            'components/Tree.qml': 'import "../../../assets/icons"\nimport "qrc:/telar/x"\nimport "/abs/path"\nItem {}\n',
            'components/Fit.js': '',
            'foundation/models/Row.qml': 'import "../../design/Pill.qml"\nItem {}\n',
            'design/Pill.qml': 'Item {}\n',
        })

        qml = graph.qml_graph(graph.load_sources(rev, self.repository))
        lines, code = self.run_report({}, rules=True)

        self.assertEqual({node: sorted(targets) for node, targets in qml.items()}, {
            'app/chrome': ['app/chrome/activity', 'components'],
            'foundation/models': ['design'],
        })
        self.assertEqual(code, 1)
        self.assertEqual(lines[lines.index('rule violations: 3'):], [
            'rule violations: 3',
            '   components is outside app, design, foundation',
            '   QML app/chrome -> components',
            '   QML foundation/models -> design',
        ])

    def test_registered_types_take_the_macro_argument_or_the_class_name(self):
        rev = self.tree({
            'app/application_controller.hpp': registered('ApplicationController'),
            'controls/chrome_style.hpp': 'class ChromeStyle final : public QObject {\n    QML_ELEMENT\n    QML_SINGLETON\n};\n',
            # The forward declaration above the class is not the registered class.
            'panes/attention.hpp': 'class WindowAnimationClock;\n\nclass NativePaneAttention : public QQuickItem {\n'
                                   '    Q_OBJECT\n    QML_ELEMENT\n};\n',
            'terminal/terminal_item.hpp': registered('TerminalItem', 'QML_NAMED_ELEMENT(TerminalView)'),
            'foundation/input/action.hpp': 'namespace action {\n    Q_NAMESPACE\n    QML_NAMED_ELEMENT(Action)\n}\n',
            # Only headers register types.
            'store/store.cpp': 'class Hidden {\n    QML_ELEMENT\n};\n',
        })

        self.assertEqual(graph.registered_types(graph.load_sources(rev, self.repository)), {
            'ApplicationController': 'app',
            'ChromeStyle': 'controls',
            'NativePaneAttention': 'panes',
            'TerminalView': 'terminal',
            'Action': 'foundation/input',
        })

    def test_qml_edges_follow_every_use_of_a_registered_type(self):
        rev = self.tree({
            'app/application_controller.hpp': registered('ApplicationController'),
            'store/store.hpp': registered('Store'),
            'terminal/terminal_item.hpp': registered('TerminalItem', 'QML_NAMED_ELEMENT(TerminalView)'),
            'peek/peek_controller.hpp': registered('PeekController'),
            'controls/chrome_style.hpp': registered('ChromeStyle', 'QML_ELEMENT'),
            'scene/clock.hpp': registered('Clock', 'QML_ELEMENT'),
            # Enum scope, property type, instantiation, attached property, parameter type.
            'palette/PalettePanel.qml': 'Item {\n    onX: execute(ApplicationController.Action.cancel)\n}\n',
            'paths/PathPanel.qml': 'Item {\n    required property PeekController peek\n}\n',
            'panes/PaneArea.qml': 'Item {\n    TerminalView {}\n}\n',
            'history/HistoryRow.qml': 'Item {\n    ChromeStyle.weight: 2\n}\n',
            'prompt/PromptPanel.qml': 'Item {\n    function pick(value: Store): bool { return true }\n}\n',
            # Comments, strings, members after a dot and the type's own folder are not edges.
            'links/LinkStatus.qml': 'Item {\n    // Clock {}\n    /* PeekController */\n'
                                    '    property string a: "TerminalView {"\n    property string b: \'Store.x\'\n'
                                    '    property var c: root.Clock\n}\n',
            'store/StoreView.qml': 'Item {\n    property int a: Store.Dialog.none\n}\n',
        })

        qml = graph.qml_graph(graph.load_sources(rev, self.repository))

        self.assertEqual({node: sorted(targets) for node, targets in qml.items() if targets}, {
            'palette': ['app'],
            'paths': ['peek'],
            'panes': ['terminal'],
            'history': ['controls'],
            'prompt': ['store'],
        })

    def test_rules_judge_registered_type_edges(self):
        lines, code = self.run_report({
            'app/application_controller.hpp': registered('ApplicationController'),
            'foundation/input/action.hpp': registered('ActionId', 'QML_NAMED_ELEMENT(Action)'),
            'app/panes/PaneActions.qml': 'Item {\n    property int a: ApplicationController.Action.copy\n'
                                         '    property int b: Action.copy\n}\n',
        }, verbose=True, rules=True)

        self.assertEqual(code, 1)
        self.assertEqual(lines[lines.index('QML edges:'):], [
            'QML edges:',
            "   app/panes -> ['app', 'foundation/input']",
            'rule violations: 1',
            '   QML app/panes -> app',
        ])

    def test_long_cycles_print_their_size_only(self):
        names = [f'f{index}' for index in range(9)]
        lines, _ = self.run_report({
            f'{name}/a.hpp': include(f'{names[(index + 1) % len(names)]}/a.hpp') for index, name in enumerate(names)
        })

        self.assertEqual(lines[2], "C++ as is edges 9 cycles: [(9, '...')]")

    def test_rules_allow_foundation_design_and_descendants(self):
        lines, code = self.run_report({
            # foundation/ uses its own subfolders; design/ uses those and foundation/.
            'foundation/models/projection.hpp': include('foundation/text/utf16_encoding.hpp'),
            'foundation/text/utf16_encoding.hpp': '',
            'design/BarPill.qml': 'Item { ElementHost {} }\n',
            'design/elements/ElementHost.qml': 'Item { ChromeText {} }\n',
            'design/controls/ChromeText.qml': 'Item {}\n',
            'design/bar_metric.hpp': include('foundation/models/projection.hpp'),
            # A directory of app/ is reachable from its parent and from any further ancestor.
            'app/application_controller.hpp': include('app/chrome/sidebar.hpp') + include('design/bar_metric.hpp')
                                              + include('app/chrome/activity/card.hpp'),
            'app/chrome/sidebar.hpp': include('app/chrome/activity/card.hpp') + include('foundation/models/projection.hpp'),
            'app/chrome/activity/card.hpp': include('design/bar_metric.hpp'),
            'app/chrome/Sidebar.qml': 'Item { BarPill {} }\n',
            'app/Main.qml': 'Item { AgentCard {} }\n',
            'app/chrome/activity/AgentCard.qml': 'Item {}\n',
        }, rules=True)

        self.assertEqual(code, 0)
        self.assertEqual(lines[-1], 'rule violations: 0')

    def test_rules_reject_each_forbidden_edge(self):
        lines, code = self.run_report({
            # foundation/ uses only foundation/.
            'foundation/models/projection.hpp': include('design/bar_metric.hpp') + include('app/chrome/sidebar.hpp'),
            # design/ uses only foundation/ and design/.
            'design/bar_metric.hpp': include('app/chrome/sidebar.hpp'),
            # A widget may not use its parent, its grandparent, a sibling or a cousin.
            'app/chrome/sidebar.hpp': include('app/application_controller.hpp') + include('app/panes/pane.hpp'),
            'app/chrome/activity/card.hpp': include('app/application_controller.hpp')
                                            + include('app/panes/terminal/item.hpp'),
            'app/application_controller.hpp': '',
            'app/panes/pane.hpp': '',
            'app/panes/terminal/item.hpp': '',
            # Every folder lives in app/, design/ or foundation/, and nobody may use one that does not.
            'scene/clock.hpp': include('chrome/bar.hpp'),
            'chrome/bar.hpp': '',
            'app/panes/PaneArea.qml': 'Item { Sidebar {} }\n',
            'app/chrome/Sidebar.qml': 'Item {}\n',
        }, rules=True)

        self.assertEqual(code, 1)
        self.assertEqual(lines[lines.index('rule violations: 11'):], [
            'rule violations: 11',
            '   chrome is outside app, design, foundation',
            '   scene is outside app, design, foundation',
            '   C++ app/chrome -> app',
            '   C++ app/chrome -> app/panes',
            '   C++ app/chrome/activity -> app',
            '   C++ app/chrome/activity -> app/panes/terminal',
            '   C++ design -> app/chrome',
            '   C++ foundation/models -> app/chrome',
            '   C++ foundation/models -> design',
            '   C++ scene -> chrome',
            '   QML app/panes -> app/chrome',
        ])

    def test_rules_reject_cycles(self):
        lines, code = self.run_report({
            'foundation/fonts/glyphs.hpp': include('foundation/scene/nodes.hpp'),
            'foundation/scene/nodes.hpp': include('foundation/fonts/glyphs.hpp'),
            'design/Pill.qml': 'Item { Ring {} }\n',
            'design/bars/Ring.qml': 'Item { Pill {} }\n',
        }, rules=True)

        self.assertEqual(code, 1)
        self.assertEqual(lines[lines.index('rule violations: 2'):], [
            'rule violations: 2',
            "   C++ cycle ['foundation/fonts', 'foundation/scene']",
            "   QML cycle ['design', 'design/bars']",
        ])


if __name__ == '__main__':
    unittest.main()
