"""Verify the rules that give every file under lib/ and src/ its place in the module tree."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('move_cpp_tree', ROOT / 'tools/move-cpp-tree.py')
tree = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tree)


def mapped(sources):
    return tree.build_map(sorted(sources), sources.get)


class TreeMoves(unittest.TestCase):
    def test_module_units_go_to_the_folder_named_after_their_module(self):
        moves, errors = mapped({
            'lib/telar-base/include/telar_base/memory.cppm': 'module;\nexport module telar.base.memory;\n',
            'lib/telar-git/include/telar_git/config.cppm': 'export module telar.git:config;\n',
            'lib/telar-platform/src/daemon.cpp': 'module;\n#include <unistd.h>\nmodule telar.platform;\n',
            'src/runtime-cpp/terminal/control.cppm': 'export module telar.runtime.terminal.control;\n',
            'src/gui-cpp/tests/controlled_awake_clock.cpp': 'module telar.gui.platform.profile_file;\n',
        })

        self.assertEqual(errors, [])
        self.assertEqual(moves, {
            'lib/telar-base/include/telar_base/memory.cppm': 'lib/base/memory/memory.cppm',
            'lib/telar-git/include/telar_git/config.cppm': 'lib/git/git-config.cppm',
            'lib/telar-platform/src/daemon.cpp': 'lib/platform/daemon.cpp',
            'src/runtime-cpp/terminal/control.cppm': 'src/runtime/terminal/control/control.cppm',
            'src/gui-cpp/tests/controlled_awake_clock.cpp': 'src/gui/platform/profile_file/controlled_awake_clock.cpp',
        })

    def test_platform_units_keep_their_platform_folder(self):
        moves, errors = mapped({
            'src/runtime-cpp/platform/process_inspector.cpp': 'module telar.runtime.platform.process_probe;\n',
            'src/runtime-cpp/platform/linux/process_inspector.cpp': 'module telar.runtime.platform.process_probe;\n',
            'src/runtime-cpp/platform/macos/process_inspector.cpp': 'module telar.runtime.platform.process_probe;\n',
        })

        folder = 'src/runtime/platform/process_probe/'
        self.assertEqual(errors, [])
        self.assertEqual(sorted(moves.values()), [
            folder + 'linux/process_inspector.cpp',
            folder + 'macos/process_inspector.cpp',
            folder + 'process_inspector.cpp',
        ])

    def test_other_files_keep_their_path_below_the_renamed_tree(self):
        moves, errors = mapped({
            'lib/telar-base/include/telar_base/memory/allocator.hpp': None,
            'lib/tbc/include/tbc/view.hpp': None,
            'src/gui-cpp/qt/application.cpp': '#include "qt/application.hpp"\n',
            'src/cli-cpp/CMakeLists.txt': None,
            'src/runtime-cpp/tests/commented.cpp': '// module telar.runtime.platform.signals;\n/* export module x; */\n',
        })

        self.assertEqual(errors, [])
        self.assertEqual(moves, {
            'lib/telar-base/include/telar_base/memory/allocator.hpp': 'lib/base/include/telar_base/memory/allocator.hpp',
            'lib/tbc/include/tbc/view.hpp': 'lib/tbc/include/tbc/view.hpp',
            'src/gui-cpp/qt/application.cpp': 'src/gui/qt/application.cpp',
            'src/cli-cpp/CMakeLists.txt': 'src/cli/CMakeLists.txt',
            'src/runtime-cpp/tests/commented.cpp': 'src/runtime/tests/commented.cpp',
        })

    def test_a_moved_tree_maps_onto_itself(self):
        sources = {
            'lib/telar-git/include/telar_git/worktree.cppm': 'export module telar.git:worktree;\n',
            'src/runtime-cpp/platform/macos/event_loop.cpp': 'module telar.runtime.platform.system_certificates;\n',
            'src/gui-cpp/README.md': None,
        }
        moves, _ = mapped(sources)

        again, errors = mapped({moves[path]: text for path, text in sources.items()})

        self.assertEqual(errors, [])
        self.assertTrue(all(source == target for source, target in again.items()))

    def test_files_without_a_valid_destination_are_reported(self):
        _, errors = mapped({
            'lib/unknown/thing.cpp': None,
            'src/gui-cpp/stray.cppm': '#include "x.hpp"\n',
            'src/gui-cpp/fonts/face.cppm': 'export module telar.runtime.fonts.face;\n',
            'src/cli-cpp/a/same.cpp': 'module telar.cli.tab;\n',
            'src/cli-cpp/b/same.cpp': 'module telar.cli.tab;\n',
        })

        self.assertEqual(len(errors), 4)
        self.assertIn('lib/unknown has no entry in ROOTS', errors[0])
        self.assertIn('would leave its tree src/gui', errors[1])
        self.assertIn('without a module declaration', errors[2])
        self.assertIn('both move to src/cli/tab/same.cpp', errors[3])

    def test_a_file_cannot_land_where_another_needs_a_folder(self):
        self.assertEqual(tree.conflicts({'src/gui-cpp/a': 'src/gui/a', 'src/gui-cpp/b': 'src/gui/a/b'}),
                         ['src/gui/a is a file and a folder'])


if __name__ == '__main__':
    unittest.main()
