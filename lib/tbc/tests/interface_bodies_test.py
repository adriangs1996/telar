"""Check rule 3 of the module layout: a module interface unit carries declarations, not function bodies."""

from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

BINARY = Path(sys.argv[1]).resolve()
INCLUDE = Path(sys.argv[2]).resolve()
SYSROOT = sys.argv[3]
COMPILER = Path(sys.argv[4]).resolve()
del sys.argv[1:]

CHECK = "[tbc-interface-body]"
# A case marks each line it expects a report on with one of these comments.
MARKS = {"// body": "function body in the interface", "// not inline": "is not inline"}
REPORT = re.compile(r"^(?P<file>[^\s:][^:]*):(?P<line>\d+):\d+: (?:warning|error): (?P<message>.*)$", re.MULTILINE)


def dedent(text):
    return textwrap.dedent(text).lstrip("\n")


class Fixture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def flags(self):
        flags = ["-std=c++23", f"-I{INCLUDE}", f"-I{self.root}", f"-fprebuilt-module-path={self.root}"]
        if SYSROOT:
            flags += ["-isysroot", SYSROOT]
        return flags

    def write(self, name, text):
        path = self.root / name
        path.write_text(dedent(text))
        return path

    def lint(self, *paths, options=()):
        command = [str(BINARY), "--checks=interface-bodies", *options, *(str(path) for path in paths), "--", *self.flags()]
        return subprocess.run(command, capture_output=True, text=True, timeout=30)

    def precompile(self, path, module):
        output = self.root / f"{module}.pcm"
        result = subprocess.run(
            [str(COMPILER), *self.flags(), "--precompile", "-x", "c++-module", str(path), "-o", str(output)],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def reports(self, result):
        return [
            (Path(match["file"]).name, int(match["line"]), match["message"])
            for match in REPORT.finditer(result.stderr)
            if CHECK in match["message"]
        ]

    def check(self, text, name="unit.cppm"):
        """Reports exactly the lines the case marks, each with the message its mark names."""
        path = self.write(name, text)
        expected = sorted(
            (index, mark)
            for index, line in enumerate(path.read_text().splitlines(), start=1)
            for mark in MARKS
            if line.rstrip().endswith(mark)
        )

        result = self.lint(path)
        self.assertEqual(result.returncode, 0, result.stderr)

        reported = sorted((line, message) for _, line, message in self.reports(result))
        self.assertEqual([line for line, _ in reported], [line for line, _ in expected], result.stderr)

        for (_, message), (_, mark) in zip(reported, expected):
            self.assertIn(MARKS[mark], message)


class InterfaceBodiesTest(Fixture):
    def test_declarations_alone_pass(self):
        self.check("""
            export module demo;

            export int compute(int value);

            export class Service {
            public:
              Service();
              Service(const Service &) = default;
              Service &operator=(const Service &) = delete;
              void run();
            };

            export template <typename type>
            type twice(type value);
            """)

    def test_bodies_are_reported(self):
        self.check("""
            export module demo;

            export int compute(int value) { // body
              return value + 1;
            }

            namespace detail {
              int helper() { // body
                return 0;
              }
            }

            export class Service {
            public:
              void run() { // body
              }

              void stop();

              friend bool operator==(const Service &, const Service &) { // body
                return true;
              }
            };

            void Service::stop() { // body
            }
            """)

    def test_templates_are_reported(self):
        self.check("""
            export module demo;

            export template <typename type>
            type twice(type value) { // body
              return value + value;
            }

            export template <typename type>
            class Box {
            public:
              type get() const { // body
                return value_;
              }

              void set(type value);

            private:
              type value_{};
            };

            template <typename type>
            void Box<type>::set(type value) { // body
              value_ = value;
            }

            int used = twice(1) + Box<int>{}.get();
            """)

    def test_constexpr_and_consteval_bodies_stay(self):
        self.check("""
            export module demo;

            export constexpr int doubled(int value) {
              return value * 2;
            }

            export consteval int tripled(int value) {
              return value * 3;
            }

            export struct Limits {
              static constexpr int largest() {
                return 64;
              }
            };
            """)

    def test_marked_inline_hot_paths_stay(self):
        self.check("""
            module;

            #include <tbc/hot_path.hpp>

            export module demo;

            export TBC_HOT_PATH inline int next(int value) {
              return value + 1;
            }

            export TBC_HOT_PATH int nextOutOfLine(int value) { // not inline
              return value + 1;
            }

            export class Cursor {
            public:
              TBC_HOT_PATH inline int advance() {
                return ++position_;
              }

              // A member defined in its class is not implicitly inline in a module.
              TBC_HOT_PATH int retreat() { // not inline
                return --position_;
              }

            private:
              int position_ = 0;
            };

            export template <typename type>
            TBC_HOT_PATH type twice(type value) {
              return value + value;
            }

            template <>
            int twice<int>(int value) { // not inline
              return value * 2;
            }
            """)

    def test_a_marked_class_covers_its_members(self):
        self.check("""
            module;

            #include <tbc/hot_path.hpp>

            export module demo;

            export template <typename type>
            class TBC_HOT_PATH Vector {
            public:
              type front() const {
                return value_;
              }

              void push(type value);

              struct Iterator {
                type operator*() const {
                  return {};
                }
              };

              friend bool operator==(const Vector &, const Vector &) {
                return true;
              }

            private:
              type value_{};
            };

            template <typename type>
            void Vector<type>::push(type value) {
              value_ = value;
            }

            // A full specialization is an ordinary class: its bodies reach importers only when inline.
            template <>
            class Vector<bool> {
            public:
              inline bool back() const {
                return true;
              }

              bool front() const { // not inline
                return false;
              }
            };

            class Plain {
              void run() { // body
              }
            };

            int used = Vector<int>{}.front();
            """)

    def test_lambdas_that_initialize_variables_are_bodies(self):
        self.check("""
            module;

            #include <tbc/hot_path.hpp>

            export module demo;

            export inline auto callback = [](int value) { // body
              return value;
            };

            export constexpr auto evaluated = [](int value) {
              return value * 2;
            };

            export TBC_HOT_PATH inline auto hot = [](int value) {
              return value;
            };

            export struct Holder {
              int (*call)(int) = [](int value) { // body
                return value;
              };
            };

            // Local classes and lambdas belong to the body that holds them.
            export int local(int value) { // body
              struct Local {
                int get() {
                  return 1;
                }
              };

              auto add = [](int left, int right) {
                return left + right;
              };

              return add(value, Local{}.get());
            }
            """)

    def test_headers_and_the_private_fragment_are_not_the_interface(self):
        self.write("helpers.hpp", """
            inline int fromHeader() {
              return 0;
            }
            """)
        self.check("""
            module;

            #include "helpers.hpp"

            export module demo;

            export int compute(int value);

            module :private;

            int compute(int value) {
              return value + fromHeader();
            }
            """)

    def test_a_partition_interface_is_checked(self):
        path = self.write("demo-part.cppm", """
            export module demo:part;

            export int compute(int value) {
              return value + 1;
            }
            """)
        result = self.lint(path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.reports(result)), 1, result.stderr)
        self.assertIn("module 'demo'", result.stderr, "a partition is reported under its module")

    def test_implementation_units_are_not_checked(self):
        interface = self.write("demo.cppm", """
            export module demo;

            export int compute(int value);
            """)
        self.precompile(interface, "demo")
        implementation = self.write("demo.cpp", """
            module demo;

            int compute(int value) {
              return value + 1;
            }
            """)
        partition = self.write("demo-detail.cppm", """
            module demo:detail;

            int helper() {
              return 0;
            }
            """)
        plain = self.write("plain.cpp", """
            int helper() {
              return 0;
            }
            """)

        result = self.lint(implementation, partition, plain)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(CHECK, result.stderr)

    def test_an_importer_does_not_report_what_it_imports(self):
        interface = self.write("demo.cppm", """
            export module demo;

            export int compute(int value) {
              return value + 1;
            }
            """)
        self.precompile(interface, "demo")
        importer = self.write("other.cppm", """
            export module other;

            import demo;

            export int twice(int value);

            int used = compute(1);
            """)

        result = self.lint(importer)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(CHECK, result.stderr)


class InterfaceAllowlistTest(Fixture):
    BODY = """
        export module {name};

        export int compute(int value) {{
          return value + 1;
        }}
        """
    CLEAN = """
        export module {name};

        export int compute(int value);
        """

    def unit(self, name, template):
        return self.write(f"{name.replace('.', '-')}.cppm", template.format(name=name))

    def test_warnings_as_errors_fail(self):
        result = self.lint(self.unit("demo", self.BODY), options=("--warnings-as-errors",))
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("error:", result.stderr)
        self.assertEqual(result.stderr.count(CHECK), 1, result.stderr)

    def test_an_allowed_module_is_not_reported(self):
        allowlist = self.write("allowlist.txt", """
            # Modules that still keep bodies in their interfaces.

            demo.alpha
            """)
        allowed = self.unit("demo.alpha", self.BODY)
        other = self.unit("demo.beta", self.BODY)

        result = self.lint(allowed, other, options=("--warnings-as-errors", f"--interface-allowlist={allowlist}"))
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count(CHECK), 1, result.stderr)
        self.assertIn("module 'demo.beta'", result.stderr)

        result = self.lint(allowed, options=("--warnings-as-errors", f"--interface-allowlist={allowlist}"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(CHECK, result.stderr)

    def test_a_clean_allowed_module_must_leave_the_allowlist(self):
        allowlist = self.write("allowlist.txt", """
            demo.alpha
            demo.unseen
            """)
        clean = self.unit("demo.alpha", self.CLEAN)

        warned = self.lint(clean, options=(f"--interface-allowlist={allowlist}",))
        self.assertEqual(warned.returncode, 0, warned.stderr)
        self.assertIn("warning: module 'demo.alpha' keeps no function body", warned.stderr)
        self.assertNotIn("demo.unseen", warned.stderr, "a module the run never saw is not judged")

        failed = self.lint(clean, options=("--warnings-as-errors", f"--interface-allowlist={allowlist}"))
        self.assertEqual(failed.returncode, 1, failed.stderr)
        self.assertIn("error: module 'demo.alpha' keeps no function body", failed.stderr)

    def test_one_partition_with_bodies_keeps_the_module_allowed(self):
        allowlist = self.write("allowlist.txt", "demo\n")
        primary = self.unit("demo", self.CLEAN)
        partition = self.write("demo-part.cppm", """
            export module demo:part;

            export int helper() {
              return 0;
            }
            """)

        result = self.lint(primary, partition, options=("--warnings-as-errors", f"--interface-allowlist={allowlist}"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(CHECK, result.stderr)

    def test_an_invalid_allowlist_fails(self):
        allowlist = self.write("allowlist.txt", "demo:part\n")
        result = self.lint(self.unit("demo", self.CLEAN), options=(f"--interface-allowlist={allowlist}",))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("allowlist.txt:1", result.stderr)

        missing = self.lint(self.unit("demo", self.CLEAN), options=(f"--interface-allowlist={self.root / 'missing.txt'}",))
        self.assertEqual(missing.returncode, 2, missing.stderr)

    def test_the_allowlist_needs_the_check(self):
        allowlist = self.write("allowlist.txt", "demo\n")
        result = subprocess.run(
            [str(BINARY), f"--interface-allowlist={allowlist}", "unit.cppm", "--"],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_other_checks_skip_interface_bodies(self):
        path = self.unit("demo", self.BODY)
        command = [str(BINARY), "--checks=lifetime,blank-lines", str(path), "--", *self.flags()]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(CHECK, result.stderr)

    def test_checks_combine(self):
        path = self.unit("demo", self.BODY)
        command = [str(BINARY), "--checks=lifetime,interface-bodies", str(path), "--", *self.flags()]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count(CHECK), 1, result.stderr)


if __name__ == "__main__":
    unittest.main()
