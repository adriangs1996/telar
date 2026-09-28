#!/usr/bin/env python3
"""Regression tests for shared-client module boundaries."""
from pathlib import Path
import tempfile
import unittest

from check_client_boundaries import imports, violations


class BoundariesTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / "client"
        self.write("client.zig", "")
        self.write("first/Public.zig", "")
        self.write("first/internal.zig", "")
        self.write("second/Consumer.zig", "")

    def write(self, name, source):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)

    def test_any_file_inside_the_package_can_be_imported(self):
        self.write("first/Public.zig", 'const detail = @import("internal.zig");')
        self.write("second/Consumer.zig", 'const detail = @import("../first/internal.zig");')
        self.assertEqual([], violations(self.root))

    def test_reverse_module_dependency_is_rejected(self):
        for module in ("telar-gui", "telar-headless", "telar-backend", "ghostty-vt", "kitty_protocol", "freetype"):
            self.write("client.zig", f'const forbidden = @import("{module}");')
            self.assertIn("forbidden module", violations(self.root)[0])

    def test_relative_escape_and_missing_files_are_rejected(self):
        self.write("client.zig", 'const window = @import("../gui/gui.zig");')
        self.assertIn("leaves telar-client", violations(self.root)[0])
        self.write("client.zig", 'const missing = @import("missing.zig");')
        self.assertIn("missing import", violations(self.root)[0])

    def test_case_only_mistakes_are_rejected_on_macos_too(self):
        self.write("second/Consumer.zig", 'const First = @import("../first/public.zig");')
        self.assertIn("missing import or incorrect case", violations(self.root)[0])

    def test_symlink_cannot_escape_the_package(self):
        target = Path(self.directory.name) / "outside.zig"
        target.write_text("")
        (self.root / "first/escape.zig").symlink_to(target)
        self.assertIn("source leaves telar-client", violations(self.root)[0])

    def test_internal_symlinks_are_rejected(self):
        (self.root / "second/Alias.zig").symlink_to(self.root / "first/internal.zig")
        self.assertIn("source aliases another file", violations(self.root)[0])

    def test_comments_and_strings_do_not_introduce_dependencies(self):
        source = '\n'.join([
            '// @import("telar-gui")',
            '\\\\ @import("telar-backend")',
            'const text = "@import(\\"fake\\")";',
            'const std = @import(\n"std"\n);',
        ])
        self.assertEqual(["std"], list(imports(source)))

    def test_native_headers_require_the_retained_graphics_exception(self):
        self.write("client.zig", '@cInclude("AppKit/AppKit.h");')
        self.assertIn("forbidden native header", violations(self.root)[0])
        self.write("client.zig", "")
        self.write("graphics/store.zig", '@cInclude("sys/stat.h");')
        self.assertEqual([], violations(self.root))

    def test_nonliteral_imports_fail_explicitly(self):
        with self.assertRaises(ValueError):
            list(imports("const indirect = @import(filename);"))


if __name__ == "__main__":
    unittest.main()
