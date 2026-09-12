#!/usr/bin/env python3
"""Regression tests for file-based shared-client capability boundaries."""
import json
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
        self.rules = {
            "entrypoint": "client.zig",
            "capabilities": [".", "first", "second"],
            "public": ["first/Public.zig"],
            "assembly_imports": ["first/internal.zig"],
        }
        self.save_policy()

    def write(self, name, source):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)

    def save_policy(self):
        self.write("capabilities.json", json.dumps(self.rules))

    def test_public_files_and_same_capability_helpers_are_allowed(self):
        self.write("first/Public.zig", 'const detail = @import("internal.zig");')
        self.write("second/Consumer.zig", 'const First = @import("../first/Public.zig");')
        self.assertEqual([], violations(self.root))
        self.assertFalse(list(self.root.rglob("root.zig")))

    def test_other_capability_helper_is_rejected(self):
        self.write("second/Consumer.zig", 'const detail = @import("../first/internal.zig");')
        self.assertIn("declared public capability file", violations(self.root)[0])

    def test_assembly_permission_does_not_make_a_helper_public(self):
        self.write("client.zig", 'test { _ = @import("first/internal.zig"); }')
        self.assertEqual([], violations(self.root))
        self.write("second/Consumer.zig", 'const detail = @import("../first/internal.zig");')
        self.assertIn("declared public capability file", violations(self.root)[0])

    def test_reverse_module_dependency_is_rejected(self):
        for module in ("telar-frontend", "telar-backend", "ghostty-vt", "kitty_protocol", "freetype"):
            self.write("client.zig", f'const forbidden = @import("{module}");')
            self.assertIn("forbidden module", violations(self.root)[0])

    def test_relative_escape_and_missing_files_are_rejected(self):
        self.write("client.zig", 'const frontend = @import("../frontend/frontend.zig");')
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

    def test_comments_and_strings_do_not_introduce_dependencies(self):
        source = '\n'.join([
            '// @import("telar-frontend")',
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
        self.rules["capabilities"].append("graphics")
        self.save_policy()
        self.assertEqual([], violations(self.root))

    def test_missing_policy_cannot_silently_pass(self):
        (self.root / "capabilities.json").unlink()
        self.assertIn("missing or invalid capability policy", violations(self.root)[0])

    def test_missing_entrypoint_cannot_silently_pass(self):
        (self.root / "client.zig").unlink()
        self.assertIn("missing or escaped public/assembly file", violations(self.root)[0])

    def test_stale_public_entries_fail(self):
        self.rules["public"].append("first/Deleted.zig")
        self.save_policy()
        self.assertIn("missing or escaped public/assembly file", violations(self.root)[0])

    def test_policy_paths_cannot_escape(self):
        self.rules["public"].append("../outside.zig")
        self.save_policy()
        self.assertIn("canonical and relative", violations(self.root)[0])

    def test_duplicate_policy_entries_fail(self):
        self.rules["capabilities"].append("first")
        self.save_policy()
        self.assertIn("duplicate capabilities entry", violations(self.root)[0])

    def test_nested_capabilities_keep_their_own_private_files(self):
        self.write("first/nested/Private.zig", "")
        self.rules["capabilities"].append("first/nested")
        self.save_policy()
        self.write("first/Public.zig", 'const Private = @import("nested/Private.zig");')
        self.assertIn("declared public capability file", violations(self.root)[0])

    def test_capability_directory_case_is_exact(self):
        self.rules["capabilities"][1] = "First"
        self.save_policy()
        self.assertIn("incorrectly cased", violations(self.root)[0])

    def test_new_directories_need_an_explicit_capability_owner(self):
        self.write("unowned/Private.zig", "")
        self.assertIn("must declare a capability", violations(self.root)[0])

    def test_internal_symlinks_cannot_change_capability_ownership(self):
        (self.root / "second/Alias.zig").symlink_to(self.root / "first/internal.zig")
        self.assertIn("source aliases another capability file", violations(self.root)[0])

    def test_nonliteral_imports_fail_explicitly(self):
        with self.assertRaises(ValueError):
            list(imports("const indirect = @import(filename);"))


if __name__ == "__main__":
    unittest.main()
