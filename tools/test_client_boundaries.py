#!/usr/bin/env python3
"""Regression tests for the shared-client dependency gate."""
from pathlib import Path
import tempfile
import unittest

from check_client_boundaries import imports, violations


class BoundariesTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / "client"
        self.write("root.zig", "")
        self.write("first/root.zig", "")
        self.write("first/internal.zig", "")
        self.write("second/root.zig", "")

    def write(self, name, source):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)

    def test_public_roots_and_same_capability_implementation_are_allowed(self):
        self.write("first/root.zig", 'const detail = @import("internal.zig");')
        self.write("second/root.zig", 'const first = @import("../first/root.zig");')
        self.assertEqual([], violations(self.root))

    def test_other_capability_implementation_is_rejected(self):
        self.write("second/root.zig", 'const first = @import("../first/internal.zig");')
        self.assertIn("import capability root", violations(self.root)[0])

    def test_reverse_module_dependency_is_rejected(self):
        self.write("root.zig", 'const frontend = @import("telar-frontend");')
        self.assertIn("forbidden module", violations(self.root)[0])

    def test_relative_escape_and_missing_files_are_rejected(self):
        self.write("root.zig", 'const frontend = @import("../frontend/root.zig");')
        self.assertIn("leaves telar-client", violations(self.root)[0])
        self.write("root.zig", 'const missing = @import("missing.zig");')
        self.assertIn("missing import", violations(self.root)[0])

    def test_comments_and_strings_do_not_introduce_dependencies(self):
        source = '\n'.join([
            '// @import("telar-frontend")',
            '\\\\ @import("telar-backend")',
            'const text = "@import(\\"fake\\")";',
            'const std = @import(\n"std"\n);',
        ])
        self.assertEqual(["std"], list(imports(source)))

    def test_native_headers_require_the_retained_graphics_exception(self):
        self.write("root.zig", '@cInclude("AppKit/AppKit.h");')
        self.assertIn("forbidden native header", violations(self.root)[0])
        self.write("root.zig", "")
        self.write("graphics/root.zig", "")
        self.write("graphics/store.zig", '@cInclude("sys/stat.h");')
        self.assertEqual([], violations(self.root))

    def test_missing_root_cannot_silently_pass(self):
        self.assertIn("missing client root", violations(self.root / "missing")[0])

    def test_nonliteral_imports_fail_explicitly(self):
        with self.assertRaises(ValueError):
            list(imports("const indirect = @import(filename);"))


if __name__ == "__main__":
    unittest.main()
