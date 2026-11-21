"""Check the blank-lines rules of docs/code-style.md: what tbc-lint reports and what --fix inserts."""

from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

BINARY = Path(sys.argv[1]).resolve()
SYSROOT = sys.argv[2]
CLANG_FORMAT = Path(sys.argv[3]).resolve()
STYLE = Path(sys.argv[4]).resolve()
del sys.argv[1:]

AFTER_BLOCK = "[tbc-blank-line-after-block]"
AFTER_DECLARATIONS = "[tbc-blank-line-after-declarations]"

PRELUDE = """\
int compute(int value);
void use(int value);
"""


def source(text):
    return PRELUDE + "\n" + textwrap.dedent(text).lstrip("\n")


class Fixture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def lint(self, *paths, options=(), flags=()):
        command = [str(BINARY), "--checks=blank-lines", *options, *(str(path) for path in paths), "--"]
        command += ["-std=c++23", f"-I{self.root}", *flags]
        if SYSROOT:
            command += ["-isysroot", SYSROOT]
        return subprocess.run(command, capture_output=True, text=True, timeout=30)

    def format(self, path):
        result = subprocess.run(
            [str(CLANG_FORMAT), f"--style=file:{STYLE}", str(path)],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def write(self, name, text):
        path = self.root / name
        path.write_text(text)
        return path

    def check(self, before, after, block=0, declarations=0):
        """Reports, fixes, and leaves a result that clang-format and a second run keep as it is."""
        before = source(before)
        after = source(after)
        path = self.write("case.cpp", before)
        self.assertEqual(self.format(path), before, "the case itself must already be formatted")

        reported = self.lint(path)
        self.assertEqual(reported.returncode, 0, reported.stderr)
        self.assertEqual(reported.stderr.count(AFTER_BLOCK), block, reported.stderr)
        self.assertEqual(reported.stderr.count(AFTER_DECLARATIONS), declarations, reported.stderr)

        fixed = self.lint(path, options=("--fix",))
        self.assertEqual(fixed.returncode, 0, fixed.stderr)
        self.assertEqual(path.read_text(), after)
        self.assertEqual(self.format(path), after, "clang-format must keep what the fix inserts")

        again = self.lint(path)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertNotIn("[tbc-blank-line", again.stderr)


class BlankLinesTest(Fixture):
    # A statement that ends on its own closing brace.

    def test_loop_closes_a_block(self):
        self.check("""
            void loops(int count) {
              for (int index = 0; index < count; ++index) {
                use(index);
              }
              while (count > 0) {
                --count;
              }
              use(count);
            }
            """, """
            void loops(int count) {
              for (int index = 0; index < count; ++index) {
                use(index);
              }

              while (count > 0) {
                --count;
              }

              use(count);
            }
            """, block=2)

    def test_if_and_switch_close_a_block(self):
        self.check("""
            void branches(int value) {
              if (value > 0) {
                use(value);
              }
              switch (value) {
              case 0:
                use(0);
                break;
              default:
                break;
              }
              use(value);
            }
            """, """
            void branches(int value) {
              if (value > 0) {
                use(value);
              }

              switch (value) {
              case 0:
                use(0);
                break;
              default:
                break;
              }

              use(value);
            }
            """, block=2)

    def test_multi_line_lambda_closes_a_block(self):
        self.check("""
            void lambdas(int value) {
              auto twice = [&](int other) {
                return other * 2;
              };
              use(twice(value));
            }
            """, """
            void lambdas(int value) {
              auto twice = [&](int other) {
                return other * 2;
              };

              use(twice(value));
            }
            """, block=1)

    def test_multi_line_braced_list_closes_a_block(self):
        self.check("""
            struct Event {
              int kind;
              int size;
            };

            void emit(const Event& event);

            void events(int kind) {
              emit(Event{
                  .kind = kind,
                  .size = 0,
              });
              use(kind);
            }
            """, """
            struct Event {
              int kind;
              int size;
            };

            void emit(const Event& event);

            void events(int kind) {
              emit(Event{
                  .kind = kind,
                  .size = 0,
              });

              use(kind);
            }
            """, block=1)

    def test_nested_blocks_and_lambda_bodies_are_checked(self):
        self.check("""
            void nested(int value) {
              auto body = [&] {
                if (value > 0) {
                  use(value);
                }
                use(0);
              };

              body();
            }
            """, """
            void nested(int value) {
              auto body = [&] {
                if (value > 0) {
                  use(value);
                }

                use(0);
              };

              body();
            }
            """, block=1)

    def test_one_line_statements_close_no_block(self):
        self.check("""
            void calls(int value) {
              use(compute(value));
              use(value);
            }
            """, """
            void calls(int value) {
              use(compute(value));
              use(value);
            }
            """)

    # What may follow a closing brace without a blank line.

    def test_else_stays_attached(self):
        self.check("""
            void attached(int value) {
              if (value > 0) {
                use(value);
              } else if (value < 0) {
                use(-value);
              } else {
                use(0);
              }
            }
            """, """
            void attached(int value) {
              if (value > 0) {
                use(value);
              } else if (value < 0) {
                use(-value);
              } else {
                use(0);
              }
            }
            """)

    def test_catch_stays_attached(self):
        self.check("""
            void caught(int value) {
              try {
                use(value);
              } catch (...) {
                use(0);
              }
              use(1);
            }
            """, """
            void caught(int value) {
              try {
                use(value);
              } catch (...) {
                use(0);
              }

              use(1);
            }
            """, block=1)

    def test_do_while_stays_attached(self):
        self.check("""
            void repeated(int value) {
              do {
                --value;
              } while (value > 0);
              use(value);
            }
            """, """
            void repeated(int value) {
              do {
                --value;
              } while (value > 0);

              use(value);
            }
            """, block=1)

    def test_closing_brace_of_the_block_needs_nothing(self):
        self.check("""
            void last(int value) {
              use(value);
              if (value > 0) {
                use(value);
              }
            }
            """, """
            void last(int value) {
              use(value);
              if (value > 0) {
                use(value);
              }
            }
            """)

    def test_case_labels_need_nothing(self):
        self.check("""
            void labels(int value) {
              switch (value) {
              case 0: {
                use(0);
              }
              case 1:
                use(1);
              }
            }
            """, """
            void labels(int value) {
              switch (value) {
              case 0: {
                use(0);
              }
              case 1:
                use(1);
              }
            }
            """)

    # A run of declarations.

    def test_declarations_are_a_block(self):
        self.check("""
            void declared(int input) {
              const int first = compute(input);
              const int second = compute(first);
              use(second);
            }
            """, """
            void declared(int input) {
              const int first = compute(input);
              const int second = compute(first);

              use(second);
            }
            """, declarations=1)

    def test_statement_before_declarations_needs_nothing(self):
        self.check("""
            void started(int input) {
              use(input);
              const int value = compute(input);

              use(value);
            }
            """, """
            void started(int input) {
              use(input);
              const int value = compute(input);

              use(value);
            }
            """)

    def test_if_checking_the_declared_variable_stays_attached(self):
        self.check("""
            void guarded(int input) {
              const int count = compute(input);
              if (count < 0) {
                return;
              }

              use(count);
            }
            """, """
            void guarded(int input) {
              const int count = compute(input);
              if (count < 0) {
                return;
              }

              use(count);
            }
            """)

    def test_if_checking_a_structured_binding_stays_attached(self):
        self.check("""
            struct Pair {
              int first;
              int second;
            };

            Pair split(int value);

            void bound(int input) {
              const auto [low, high] = split(input);
              if (high < low) {
                return;
              }

              use(low);
            }
            """, """
            struct Pair {
              int first;
              int second;
            };

            Pair split(int value);

            void bound(int input) {
              const auto [low, high] = split(input);
              if (high < low) {
                return;
              }

              use(low);
            }
            """)

    def test_if_after_a_multi_line_declaration_stays_attached(self):
        self.check("""
            struct Options {
              int size;
              int count;
            };

            int run(const Options& options);

            void configured(int size) {
              const int result = run(Options{
                  .size = size,
                  .count = 1,
              });
              if (result < 0) {
                return;
              }

              use(result);
            }
            """, """
            struct Options {
              int size;
              int count;
            };

            int run(const Options& options);

            void configured(int size) {
              const int result = run(Options{
                  .size = size,
                  .count = 1,
              });
              if (result < 0) {
                return;
              }

              use(result);
            }
            """)

    def test_if_checking_an_earlier_declaration_is_separated(self):
        self.check("""
            void earlier(int input) {
              const int first = compute(input);
              const int second = compute(input);
              if (first < 0) {
                return;
              }

              use(second);
            }
            """, """
            void earlier(int input) {
              const int first = compute(input);
              const int second = compute(input);

              if (first < 0) {
                return;
              }

              use(second);
            }
            """, declarations=1)

    def test_if_checking_something_else_is_separated(self):
        self.check("""
            void unrelated(int input) {
              const int value = compute(input);
              if (input < 0) {
                return;
              }

              use(value);
            }
            """, """
            void unrelated(int input) {
              const int value = compute(input);

              if (input < 0) {
                return;
              }

              use(value);
            }
            """, declarations=1)

    # A trace at the top of a function.

    def test_trace_declaring_a_scope_needs_nothing(self):
        self.check("""
            #define TRACE(name) const int trace_scope_##name = compute(0)

            void traced(int input) {
              TRACE(traced);
              use(input);
            }
            """, """
            #define TRACE(name) const int trace_scope_##name = compute(0)

            void traced(int input) {
              TRACE(traced);
              use(input);
            }
            """)

    def test_trace_compiled_out_needs_nothing(self):
        self.check("""
            #define TRACE(name) static_cast<void>(0)

            void traced(int input) {
              TRACE(traced);
              const int value = compute(input);

              use(value);
            }
            """, """
            #define TRACE(name) static_cast<void>(0)

            void traced(int input) {
              TRACE(traced);
              const int value = compute(input);

              use(value);
            }
            """)

    # Where the blank line goes and what is never touched.

    def test_blank_line_goes_above_the_comment_of_the_next_block(self):
        self.check("""
            void commented(int input) {
              const int value = compute(input);
              // The next block uses the value.
              use(value);
            }
            """, """
            void commented(int input) {
              const int value = compute(input);

              // The next block uses the value.
              use(value);
            }
            """, declarations=1)

    def test_existing_blank_lines_are_kept(self):
        self.check("""
            void separated(int input) {
              use(input);

              use(compute(input));
              const int value = compute(input);
              // A blank line above a comment already separates the blocks.

              use(value);
            }
            """, """
            void separated(int input) {
              use(input);

              use(compute(input));
              const int value = compute(input);
              // A blank line above a comment already separates the blocks.

              use(value);
            }
            """)

    def test_templates_are_checked_once(self):
        self.check("""
            template <typename T>
            void generic(T value) {
              const T copy = value;
              use(copy);
            }

            void instantiate() {
              generic(1);
              generic(2L);
            }
            """, """
            template <typename T>
            void generic(T value) {
              const T copy = value;

              use(copy);
            }

            void instantiate() {
              generic(1);
              generic(2L);
            }
            """, declarations=1)


class BlankLinesCommandTest(Fixture):
    UNFORMATTED = source("""
        void declared(int input) {
          const int value = compute(input);
          use(value);
        }
        """)

    def test_warnings_as_errors_fail(self):
        path = self.write("case.cpp", self.UNFORMATTED)
        result = self.lint(path, options=("--warnings-as-errors",))
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("error:", result.stderr)
        self.assertEqual(result.stderr.count(AFTER_DECLARATIONS), 1, result.stderr)

    def test_lifetime_alone_reports_no_blank_lines(self):
        path = self.write("case.cpp", self.UNFORMATTED)
        command = [str(BINARY), str(path), "--", "-std=c++23"]
        if SYSROOT:
            command += ["-isysroot", SYSROOT]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("[tbc-blank-line", result.stderr)

    def test_fix_needs_the_check(self):
        result = subprocess.run([str(BINARY), "--fix", "case.cpp", "--"], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_invalid_code_is_neither_reported_nor_fixed(self):
        text = self.UNFORMATTED + "missing();\n"
        path = self.write("case.cpp", text)
        result = self.lint(path, options=("--fix",))
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("[tbc-blank-line", result.stderr)
        self.assertEqual(path.read_text(), text)

    def test_headers_need_the_filter(self):
        header = textwrap.dedent("""\
            #pragma once

            int compute(int value);
            void use(int value);

            inline void declared(int input) {
              const int value = compute(input);
              use(value);
            }
            """)
        self.write("shared.hpp", header)
        main = self.write("main.cpp", '#include "shared.hpp"\n')

        unfiltered = self.lint(main, options=("--fix",))
        self.assertEqual(unfiltered.returncode, 0, unfiltered.stderr)
        self.assertNotIn("[tbc-blank-line", unfiltered.stderr)
        self.assertEqual((self.root / "shared.hpp").read_text(), header)

        other = self.write("other.cpp", '#include "shared.hpp"\n')
        filtered = self.lint(main, other, options=("--fix", "--header-filter=shared\\.hpp$"))
        self.assertEqual(filtered.returncode, 0, filtered.stderr)
        self.assertEqual(filtered.stderr.count(AFTER_DECLARATIONS), 1, "a header shared by two units is reported once")
        self.assertEqual((self.root / "shared.hpp").read_text(), header.replace("compute(input);\n", "compute(input);\n\n"))

    def test_a_scope_limits_the_check_to_its_sources(self):
        text = source("""
            void declared(int input) {
              const int value = compute(input);
              use(value);
            }
            """)
        inside = self.write("inside.cpp", text)
        outside = self.write("outside.cpp", text)
        scope = self.write("scope", f"{inside}\n")

        result = self.lint(inside, outside, options=(f"--scope=blank-lines={scope}",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count(AFTER_DECLARATIONS), 1, result.stderr)
        self.assertIn("inside.cpp", result.stderr)
        self.assertNotIn("outside.cpp:", result.stderr)

        invalid = self.lint(inside, options=(f"--scope=unknown={scope}",))
        self.assertEqual(invalid.returncode, 2, invalid.stderr)

    def test_a_replayed_unit_keeps_its_report_and_its_claim(self):
        self.write("shared.hpp", textwrap.dedent("""\
            #pragma once

            int compute(int value);
            void use(int value);

            inline void declared(int input) {
              const int value = compute(input);
              use(value);
            }
            """))
        main = self.write("main.cpp", '#include "shared.hpp"\n')
        other = self.write("other.cpp", '#include "shared.hpp"\n')
        stamps = self.root / "stamps"
        stamps.mkdir()
        options = ("--header-filter=shared\\.hpp$", f"--stamps={stamps}")

        checked = self.lint(main, options=options)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertEqual(checked.stderr.count(AFTER_DECLARATIONS), 1, checked.stderr)

        # main is replayed while other is checked: the header is reported by main's stamp alone.
        replay = self.write("replay", f"{main}\n")
        replayed = self.lint(other, options=(*options, f"--replay={replay}"))
        self.assertEqual(replayed.returncode, 0, replayed.stderr)
        self.assertEqual(replayed.stderr.count(AFTER_DECLARATIONS), 1, replayed.stderr)


if __name__ == "__main__":
    unittest.main()
