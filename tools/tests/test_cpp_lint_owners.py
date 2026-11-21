"""Check how the lint driver gives each header of the project to one of the units that include it."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[2] / 'cmake/scripts/clang_tidy.py'
spec = importlib.util.spec_from_file_location('clang_tidy_driver', MODULE)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class NinjaDependencies(unittest.TestCase):
    def test_each_object_lists_the_files_under_its_line(self):
        listing = (
            'src/a.cpp.o: #deps 2, deps mtime 1 (VALID)\n'
            '    /project/src/a.cpp\n'
            '    /project/src/a.hpp\n'
            '\n'
            'lib/b.cpp.o: #deps 1, deps mtime 2 (VALID)\n'
            '    /project/lib/b.cpp\n'
        )
        self.assertEqual(driver.dependencies(listing, '/project/out'), {
            '/project/out/src/a.cpp.o': ['/project/src/a.cpp', '/project/src/a.hpp'],
            '/project/out/lib/b.cpp.o': ['/project/lib/b.cpp'],
        })


class ProjectHeaders(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.project = os.path.realpath(self.directory.name)
        self.build = os.path.join(self.project, 'out')

    def tearDown(self):
        self.directory.cleanup()

    def path(self, name):
        return os.path.join(self.project, name)

    def test_a_unit_has_the_project_files_it_includes_besides_itself(self):
        units = {self.path('src/a.cpp'): Path(self.build, 'a.o')}
        files = {os.path.join(self.build, 'a.o'): [
            self.path('src/a.cpp'),
            self.path('src/a.hpp'),
            self.path('src/detail/../shared.hpp'),
            os.path.join(self.build, 'generated.inc'),
            '/usr/include/stdio.h',
        ]}
        headers = driver.project_headers(units, files, self.project, self.build)
        self.assertEqual(headers, {self.path('src/a.cpp'): {self.path('src/a.hpp'), self.path('src/shared.hpp')}})

    def test_a_unit_without_a_record_gives_no_owners(self):
        units = {self.path('src/a.cpp'): Path(self.build, 'a.o'), self.path('src/b.cpp'): Path(self.build, 'b.o')}
        files = {os.path.join(self.build, 'a.o'): [self.path('src/a.cpp')]}
        self.assertIsNone(driver.project_headers(units, files, self.project, self.build))


class OwnedHeaders(unittest.TestCase):
    def test_every_header_goes_to_one_unit_that_includes_it(self):
        headers = {
            '/p/src/ui/panel.cpp': {'/p/src/ui/panel.hpp', '/p/src/ui/shared.hpp', '/p/lib/base/values.hpp'},
            '/p/src/ui/dialog.cpp': {'/p/src/ui/panel.hpp', '/p/src/ui/shared.hpp'},
            '/p/lib/base/base.cpp': {'/p/lib/base/values.hpp'},
            '/p/lib/base/alone.cpp': set(),
        }
        owned = driver.owned_headers(headers)
        # The unit beside a header that bears its name; else the nearest in the tree, and of two
        # equally near the first by name.
        self.assertEqual(owned, {
            '/p/src/ui/panel.cpp': ['/p/src/ui/panel.hpp'],
            '/p/src/ui/dialog.cpp': ['/p/src/ui/shared.hpp'],
            '/p/lib/base/base.cpp': ['/p/lib/base/values.hpp'],
            '/p/lib/base/alone.cpp': [],
        })
        given = [header for listed in owned.values() for header in listed]
        self.assertEqual(sorted(given), sorted(set().union(*headers.values())))


if __name__ == '__main__':
    unittest.main()
