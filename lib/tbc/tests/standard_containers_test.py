"""Check that telar code uses telar::ds rather than the standard containers it replaces."""

from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

BINARY = Path(sys.argv[1]).resolve()
SYSROOT = sys.argv[2]
del sys.argv[1:]

REPORT = re.compile(r"^(?P<file>[^\s:][^:]*):(?P<line>\d+):\d+: (?:warning|error): (?P<message>.*\[tbc-standard-container\])$", re.MULTILINE)


class StandardContainers(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(text).lstrip("\n"))
        return path

    def lint(self, *paths, options=()):
        flags = ["-std=c++23"] + (["-isysroot", SYSROOT] if SYSROOT else [])
        command = [str(BINARY), "--checks=standard-containers", *options, *(str(path) for path in paths), "--", *flags]
        return subprocess.run(command, capture_output=True, text=True, timeout=60)

    def reports(self, result):
        return [(Path(match["file"]).name, int(match["line"]), match["message"]) for match in REPORT.finditer(result.stderr)]

    def test_reports_each_replaced_container(self):
        source = self.write("project/source.cpp", """
            #include <array>
            #include <functional>
            #include <map>
            #include <optional>
            #include <span>
            #include <string>
            #include <string_view>
            #include <unordered_map>
            #include <vector>

            struct record {
              std::vector<int> items;
              std::array<int, 4> fixed;
              std::optional<int> maybe;
              std::string text;
              std::map<int, int> ordered;
              std::unordered_map<int, int> hashed;
              std::function<void()> callback;
              int raw[4];
              std::string_view view;
              std::span<const int> span;
            };
            """)
        result = self.lint(source)
        found = {(line, message.split(" is ")[0]) for _, line, message in self.reports(result)}

        self.assertEqual(found, {
            (12, "std::vector"),
            (13, "std::array"),
            (14, "std::optional"),
            (15, "std::string"),
            (16, "std::map"),
            (17, "std::unordered_map"),
            (18, "std::function"),
            (19, "a C array"),
        }, result.stderr)
        self.assertIn("use telar::ds::Vec", result.stderr)

    def test_reports_a_qualified_container(self):
        source = self.write("project/source.cpp", """
            #include <array>
            #include <string>
            #include <vector>

            void read() {
              const std::vector<int> values;
              constexpr std::array<int, 2> folded{};
              static constexpr std::array<int, 2> kept{};
              volatile std::string text;
            }
            """)
        result = self.lint(source)
        found = {(line, message.split(" is ")[0]) for _, line, message in self.reports(result)}

        self.assertEqual(found, {
            (6, "std::vector"),
            (7, "std::array"),
            (8, "std::array"),
            (9, "std::string"),
        }, result.stderr)

    def test_allowlist_permits_a_folder_and_reports_it_once_unused(self):
        legacy = self.write("project/legacy/source.cpp", """
            #include <vector>

            std::vector<int> values;
            """)
        migrated = self.write("project/migrated/source.cpp", """
            int value = 0;
            """)
        allowlist = self.write("allowlist.txt", """
            # Folders still being migrated.
            project/legacy/
            project/migrated/
            """)
        result = self.lint(legacy, migrated, options=(f"--standard-containers-allowlist={allowlist}",))

        self.assertEqual(self.reports(result), [], result.stderr)
        self.assertIn("'project/migrated/' uses no container telar::ds replaces", result.stderr)
        self.assertNotIn("'project/legacy/'", result.stderr)

    def test_rejects_an_absolute_entry(self):
        source = self.write("project/source.cpp", "int value = 0;\n")
        allowlist = self.write("allowlist.txt", "/project/\n")
        result = self.lint(source, options=(f"--standard-containers-allowlist={allowlist}",))

        self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == "__main__":
    unittest.main()
