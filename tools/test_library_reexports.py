#!/usr/bin/env python3
"""Exercise the library re-export rule with isolated source trees."""
import tempfile
import unittest
from pathlib import Path

from check_library_reexports import violations


class LibraryReexports(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.write("lib/cellgrid/root.zig", 'pub const Rect = @import("Rect.zig");')

    def write(self, name, source):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)

    def test_private_aliases_are_allowed(self):
        self.write("src/core/core.zig", 'const cellgrid = @import("cellgrid");\nconst Rect = cellgrid.Rect;\n')
        self.assertEqual([], violations(self.root))

    def test_public_member_is_rejected(self):
        self.write("src/core/core.zig", 'const cellgrid = @import("cellgrid");\npub const Rect = cellgrid.Rect;\n')
        self.assertIn("re-exporting", violations(self.root)[0])

    def test_public_member_through_an_alias_is_rejected(self):
        self.write("src/core/core.zig", 'const cellgrid = @import("cellgrid");\nconst text = cellgrid.text;\npub const measure = text.measure;\n')
        self.assertIn("core.zig:3", violations(self.root)[0])

    def test_libraries_may_publish_their_own_members(self):
        self.write("lib/gfx/root.zig", 'const cellgrid = @import("cellgrid");\npub const Rect = cellgrid.Rect;\n')
        self.assertEqual([], violations(self.root))


if __name__ == "__main__":
    unittest.main()
