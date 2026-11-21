"""Check that clang-tidy with tbc-tidy-scope reports about a unit's own code what it reports without it,
and leaves what the unit imports to the unit that defines it."""

from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

PLUGIN = Path(sys.argv[1]).resolve()
CLANG_TIDY = Path(sys.argv[2]).resolve()
SYSROOT = sys.argv[3]
COMPILER = Path(sys.argv[4]).resolve()
del sys.argv[1:]

# Checks that ask for a node's parents or walk the unit themselves, which is what the plugin limits.
CHECKS = "readability-identifier-length,misc-no-recursion,modernize-use-using,bugprone-reserved-identifier"
REPORT = re.compile(r"^(?P<file>[^\s:][^:]*):(?P<line>\d+):\d+: (?:warning|error): .*\[(?P<check>[a-z0-9,-]+)\]$", re.MULTILINE)


class TidyScopeTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name).resolve()

    def tearDown(self):
        self.directory.cleanup()

    def flags(self):
        flags = ["-std=c++23", f"-fprebuilt-module-path={self.root}", "-isystem", str(self.root / "system")]
        return flags + (["-isysroot", SYSROOT] if SYSROOT else [])

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(text).lstrip("\n"))
        return path

    def precompile(self, path, module):
        command = [str(COMPILER), *self.flags(), "--precompile", "-x", "c++-module", str(path), "-o", str(self.root / f"{module}.pcm")]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)

    def reports(self, path, plugin):
        """The (file, line, check) of each report on a unit, with the plugin or without it."""
        checks = CHECKS + (",tbc-parsed-scope" if plugin else "")
        command = [str(CLANG_TIDY), *([f"--load={PLUGIN}"] if plugin else []), f"--config={{Checks: '-*,{checks}', HeaderFilterRegex: '.*'}}", str(path), "--", *self.flags()]
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        self.assertNotIn("error: ", result.stderr, result.stderr)
        return sorted((Path(match["file"]).name, int(match["line"]), match["check"]) for match in REPORT.finditer(result.stdout))

    def test_a_unit_reports_the_same_about_its_own_code(self):
        self.precompile(self.write("base.cppm", """
            export module base;

            export int twice(int ab);
            """), "base")
        unit = self.write("unit.cpp", """
            import base;

            int recurse(int value) {
              return value > 0 ? recurse(value - 1) : twice(value);
            }

            int shorten(int value) {
              int ab = value;
              return ab;
            }

            typedef int legacy;
            int _Reserved = 0;
            """)
        own = [
            ("unit.cpp", 3, "misc-no-recursion"),
            ("unit.cpp", 8, "readability-identifier-length"),
            ("unit.cpp", 12, "modernize-use-using"),
            ("unit.cpp", 13, "bugprone-reserved-identifier"),
        ]

        self.assertEqual([report for report in self.reports(unit, plugin=False) if report[0] == "unit.cpp"], own)
        self.assertEqual(self.reports(unit, plugin=True), own)

    def test_an_interface_is_reported_with_its_own_unit(self):
        base = self.write("base.cppm", """
            export module base;

            export inline int countdown(int value) {
              return value > 0 ? countdown(value - 1) : 0;
            }
            """)
        self.precompile(base, "base")
        unit = self.write("unit.cpp", """
            import base;

            int two() {
              return countdown(2);
            }
            """)
        recursion = [("base.cppm", 3, "misc-no-recursion")]

        # Without the plugin every unit that imports the interface walks it and reports it again.
        self.assertEqual(self.reports(unit, plugin=False), recursion)
        self.assertEqual(self.reports(unit, plugin=True), [])
        self.assertEqual(self.reports(base, plugin=True), recursion)

    def test_a_unit_that_imports_nothing_reports_the_same(self):
        self.write("system/library.h", """
            int library(int ab);
            typedef int library_legacy;
            """)
        unit = self.write("unit.cpp", """
            #include <library.h>

            int shorten(int value) {
              int ab = library(value);
              return ab;
            }

            typedef int legacy;
            """)
        own = [
            ("unit.cpp", 4, "readability-identifier-length"),
            ("unit.cpp", 8, "modernize-use-using"),
        ]

        self.assertEqual(self.reports(unit, plugin=False), own)
        self.assertEqual(self.reports(unit, plugin=True), own)


if __name__ == "__main__":
    unittest.main()
