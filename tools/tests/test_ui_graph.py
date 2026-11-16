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

    def test_long_cycles_print_their_size_only(self):
        names = [f'f{index}' for index in range(9)]
        lines, _ = self.run_report({
            f'{name}/a.hpp': include(f'{names[(index + 1) % len(names)]}/a.hpp') for index, name in enumerate(names)
        })

        self.assertEqual(lines[2], "C++ as is edges 9 cycles: [(9, '...')]")

    def test_rules_allow_foundation_design_and_children(self):
        lines, code = self.run_report({
            'foundation/models/projection.hpp': include('foundation/text/utf16_encoding.hpp'),
            'foundation/text/utf16_encoding.hpp': '',
            'design/BarPill.qml': 'Item {}\n',
            'design/bar_metric.hpp': include('foundation/models/projection.hpp'),
            'app/application_controller.hpp': include('app/chrome/sidebar.hpp') + include('design/bar_metric.hpp'),
            'app/chrome/sidebar.hpp': include('app/chrome/activity/card.hpp') + include('foundation/models/projection.hpp'),
            'app/chrome/activity/card.hpp': include('design/bar_metric.hpp'),
            'app/chrome/Sidebar.qml': 'Item { BarPill {} }\n',
        }, rules=True)

        self.assertEqual(code, 0)
        self.assertEqual(lines[-1], 'rule violations: 0')

    def test_rules_reject_each_forbidden_edge(self):
        lines, code = self.run_report({
            # foundation/ may not use design/.
            'foundation/models/projection.hpp': include('design/bar_metric.hpp'),
            'design/bar_metric.hpp': '',
            # A widget may not use its parent, its grandchild or a sibling.
            'app/chrome/sidebar.hpp': include('app/application_controller.hpp') + include('app/panes/pane.hpp'),
            'app/application_controller.hpp': include('app/chrome/activity/card.hpp'),
            'app/chrome/activity/card.hpp': '',
            'app/panes/pane.hpp': '',
            # Folders outside app/ that are not foundation/ or design/ are nobody's children.
            'scene/clock.hpp': include('chrome/bar.hpp'),
            'chrome/bar.hpp': '',
            'app/panes/PaneArea.qml': 'Item { Sidebar {} }\n',
            'app/chrome/Sidebar.qml': 'Item {}\n',
        }, rules=True)

        self.assertEqual(code, 1)
        self.assertEqual(lines[lines.index('rule violations: 6'):], [
            'rule violations: 6',
            '   C++ app -> app/chrome/activity',
            '   C++ app/chrome -> app',
            '   C++ app/chrome -> app/panes',
            '   C++ foundation/models -> design',
            '   C++ scene -> chrome',
            '   QML app/panes -> app/chrome',
        ])


if __name__ == '__main__':
    unittest.main()
