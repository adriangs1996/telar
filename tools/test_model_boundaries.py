#!/usr/bin/env python3
"""Exercise the model dependency boundary with isolated source trees."""
import tempfile
import unittest
from pathlib import Path

from check_model_boundaries import violations


class ModelBoundaries(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.write("src/model/model.zig", 'pub const Value = @import("Value.zig");')
        self.write("src/model/Value.zig", 'const core = @import("telar-core");')

    def write(self, name, source):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)

    def test_named_consumers_and_core_dependency(self):
        self.write("src/client/client.zig", 'const data = @import("model");')
        self.assertEqual([], violations(self.root))

    def test_model_rejects_service_dependencies(self):
        for dependency in ("telar-client", "telar-backend", "telar-gui", "telar-headless", "telar-lua"):
            with self.subTest(dependency=dependency):
                self.write("src/model/Value.zig", f'const service = @import("{dependency}");')
                self.assertTrue(any("forbidden model dependency" in e for e in violations(self.root)))

    def test_model_rejects_relative_escape(self):
        self.write("src/model/Value.zig", 'const service = @import("../client/Service.zig");')
        self.assertTrue(any("escapes" in e for e in violations(self.root)))

    def test_consumers_cannot_bypass_public_api(self):
        self.write("src/client/client.zig", 'const Value = @import("../model/Value.zig");')
        self.assertTrue(any("public" in e for e in violations(self.root)))

    def test_core_cannot_depend_on_model(self):
        self.write("src/core/core.zig", 'const data = @import("model");')
        self.assertTrue(any("reverse dependency" in e for e in violations(self.root)))

    def test_casing_and_missing_files(self):
        self.write("src/model/model.zig", 'const Value = @import("value.zig");')
        self.assertTrue(any("incorrectly cased" in e for e in violations(self.root)))

    def test_native_services_are_rejected(self):
        self.write("src/model/Value.zig", 'const c = @cImport({ @cInclude("unistd.h"); });')
        self.assertTrue(any("native services" in e for e in violations(self.root)))


if __name__ == "__main__":
    unittest.main()
