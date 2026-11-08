"""Verify clean and incremental lint preparation with a tiny native module graph."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CMAKE = ROOT / '.toolchain/bin/cmake'
CHAIN = ROOT / '.toolchain/toolchain.cmake'


@unittest.skipUnless(CMAKE.exists() and CHAIN.exists(),
                     'requires the prepared pinned SDK; never downloads or builds a toolchain')
class ModuleLintPreparation(unittest.TestCase):
    def test_clean_lint_prepares_all_selected_contexts_incrementally(self):
        with tempfile.TemporaryDirectory(prefix='telar-lint + ') as temporary:
            root = Path(temporary).resolve() / 'tests'
            source = root / 'src/runtime-cpp'
            binary = root / 'binary'
            (source / 'tools').mkdir(parents=True)
            (source / 'tests').mkdir()
            (source / 'seed.hpp').write_text('#define LINT_VALUE 7\n')
            (source / 'api.cppm').write_text('''module;
#include "generated.hpp"
export module lint.fixture;
export constexpr int fixture_value() { return LINT_VALUE; }
''')
            importer = 'import lint.fixture;\nint main() { return fixture_value() == 7 ? 0 : 1; }\n'
            (source / 'main.cpp').write_text(importer)
            (source / 'tools/hidden.cpp').write_text(importer)
            (source / 'tests/never.cpp').write_text('#error Unrelated tests must not be built or linted\n')
            (source / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 4.4.5)
project(lint_fixture LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_SCAN_FOR_MODULES ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
add_custom_command(OUTPUT "${CMAKE_BINARY_DIR}/generated.hpp"
  COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_SOURCE_DIR}/seed.hpp" "${CMAKE_BINARY_DIR}/generated.hpp"
  DEPENDS seed.hpp)
add_custom_target(generate-header DEPENDS "${CMAKE_BINARY_DIR}/generated.hpp")
add_library(provider STATIC)
target_sources(provider PUBLIC FILE_SET CXX_MODULES FILES api.cppm)
target_include_directories(provider PRIVATE "${CMAKE_BINARY_DIR}")
add_dependencies(provider generate-header)
add_executable(importer main.cpp)
target_link_libraries(importer PRIVATE provider)
add_executable(hidden-tool EXCLUDE_FROM_ALL tools/hidden.cpp)
target_link_libraries(hidden-tool PRIVATE provider)
add_executable(unrelated-tests tests/never.cpp)
''')
            env = dict(os.environ, PATH=str(CMAKE.parent) + os.pathsep + os.environ['PATH'])
            def run(*args):
                return subprocess.run([str(arg) for arg in args], env=env, text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            configured = run(CMAKE, '-S', source, '-B', binary, '-G', 'Ninja',
                             '-DCMAKE_BUILD_TYPE=Debug', '-DCMAKE_TOOLCHAIN_FILE=' + str(CHAIN),
                             '-DCMAKE_CXX_COMPILER=' + str(ROOT / '.toolchain/bin/clang++'))
            self.assertEqual(configured.returncode, 0, configured.stdout)
            entries = json.loads((binary / 'compile_commands.json').read_text())
            selected = [entry for entry in entries
                        if Path(entry['file']).relative_to(source).parts[0] != 'tests']
            outputs = [Path(entry['output']) for entry in selected]
            self.assertFalse(any(path.exists() for path in outputs))
            command = [CMAKE, '-DRUNTIME_BUILD_DIRECTORY=' + str(binary), '-DJOBS=2',
                       '-P', ROOT / 'src/runtime-cpp/cmake/lint.cmake']
            first = run(*command)
            self.assertEqual(first.returncode, 0, first.stdout)
            self.assertIn('for 3 files', first.stdout)
            self.assertTrue(all(path.exists() for path in outputs), first.stdout)
            self.assertTrue(list(binary.rglob('*.pcm')), first.stdout)
            self.assertEqual((binary / 'generated.hpp').read_text(), '#define LINT_VALUE 7\n')
            self.assertTrue(list(binary.rglob('hidden.cpp.o.modmap')))
            self.assertFalse(list(binary.rglob('never.cpp.o')))
            stamps = [path.stat().st_mtime_ns for path in outputs]
            second = run(*command)
            self.assertEqual(second.returncode, 0, second.stdout)
            self.assertIn('no work to do', second.stdout)
            self.assertEqual(stamps, [path.stat().st_mtime_ns for path in outputs])

            # Direct script calls must refresh the database before selecting a
            # newly added tool; no explicit reconfiguration or prior build.
            (source / 'tools/added.cpp').write_text(importer)
            with (source / 'CMakeLists.txt').open('a') as project:
                project.write('add_executable(added-tool EXCLUDE_FROM_ALL tools/added.cpp)\n'
                              'target_link_libraries(added-tool PRIVATE provider)\n')
            third = run(*command)
            self.assertEqual(third.returncode, 0, third.stdout)
            self.assertIn('for 4 files', third.stdout)
            self.assertTrue(list(binary.rglob('added.cpp.o.modmap')))
            self.assertTrue(list(binary.rglob('added.cpp.o')))
            self.assertEqual(stamps, [path.stat().st_mtime_ns for path in outputs])


if __name__ == '__main__':
    unittest.main()
