#!/usr/bin/env python3
import json
from pathlib import Path
import struct
import tempfile
import unittest

from compare_zig_tests import compare, executable_paths, metadata, named


def packet(names):
    strings = b""
    indices = []
    for name in names:
        indices.append(len(strings))
        strings += name.encode() + b"\0"
    body = struct.pack("<II", len(strings), len(names))
    body += struct.pack("<" + "I" * len(names), *indices)
    body += bytes(4 * len(names)) + strings
    return struct.pack("<II", 3, len(body)) + body


class InventoryTests(unittest.TestCase):
    def test_metadata_keeps_named_and_anonymous_tests(self):
        names = ["buffer.test.unicode é", "buffer.test_0"]
        self.assertEqual(names, metadata(packet(names)))

    def test_other_server_messages_do_not_hide_metadata(self):
        self.assertEqual(["a.test.roundtrip"], metadata(struct.pack("<II", 0, 0) + packet(["a.test.roundtrip"])))

    def test_malformed_metadata_fails_explicitly(self):
        valid = packet(["x"])
        for data in (b"", b"a", valid[:-1], valid + valid, struct.pack("<IIII", 3, 8, 0, 4)):
            with self.subTest(data=data), self.assertRaises(ValueError):
                metadata(data)
        missing_zero = valid[:-1] + b"x"
        with self.assertRaises(ValueError):
            metadata(missing_zero)
        invalid_offset = bytearray(valid)
        struct.pack_into("<I", invalid_offset, 16, 99)
        with self.assertRaises(ValueError):
            metadata(invalid_offset)

    def test_normalization_does_not_confuse_test_filename_suffixes(self):
        self.assertEqual({"roundtrip": 2}, named(["codec_test.test.roundtrip", "nested.codec.test.roundtrip", "codec.test_0"]))

    def test_duplicate_execution_is_reported_separately_from_missing_names(self):
        before = {"tests": ["a.test.keep", "b.test.keep", "a.test.lost"], "binaries": []}
        after = {"tests": ["Renamed.test.keep", "new.test.added"], "binaries": []}
        result = compare(before, after)
        self.assertEqual(["lost"], result["missing_names"])
        self.assertEqual(["added"], result["added_names"])
        self.assertEqual({"keep": 1, "lost": 1}, result["fewer_repetitions"])
        json.dumps(result)

    def test_verbose_logs_deduplicate_executables_and_support_spaces(self):
        with tempfile.TemporaryDirectory(prefix="zig tests ") as directory:
            root = Path(directory)
            executable = root / ".zig-cache/o/abc/test"
            log = root / "build.log"
            log.write_text(f"'{executable}' --seed=1 --listen=-\nfailed command: '{executable}' --listen=-\n.../.zig-cache/o/abc/test --listen=-\n...../.zig-cache/o/abc/test --listen=-\n")
            self.assertEqual([".zig-cache/o/abc/test"], executable_paths(root, log))

    def test_logs_cannot_select_executables_outside_the_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "build.log"
            for text in ("no verbose output", "/elsewhere/.zig-cache/o/abc/test --listen=-", "../.zig-cache/o/abc/test --listen=-", "not-dots/.zig-cache/o/abc/test --listen=-"):
                log.write_text(text)
                with self.assertRaises(ValueError):
                    executable_paths(root, log)


if __name__ == "__main__":
    unittest.main()
