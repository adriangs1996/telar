"""Exercise the public C++ contracts and CLI without treating them as memory proofs."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = Path(sys.argv[1]).resolve()
INCLUDE = Path(sys.argv[2]).resolve()
SYSROOT = sys.argv[3]
COMPILER = Path(sys.argv[4]).resolve()
FIXTURES = Path(__file__).parent / "fixtures"
del sys.argv[1:]


class LinterTest(unittest.TestCase):
    def run_linter(self, fixture, *options, others=()):
        command = [str(BINARY), *options, str(FIXTURES / fixture), *(str(FIXTURES / other) for other in others), "--"]
        command += ["-std=c++23", f"-I{INCLUDE}", "-Wno-return-stack-address"]
        if SYSROOT:
            command += ["-isysroot", SYSROOT]
        return subprocess.run(command, capture_output=True, text=True, timeout=20)

    def test_safe_referents(self):
        result = self.run_linter("valid.cpp", "--warnings-as-errors")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("[tbc-dangling-borrow]", result.stderr)

    def test_warnings_are_nonfatal(self):
        result = self.run_linter("dangling.cpp")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count("[tbc-dangling-borrow]"), 3, result.stderr)
        self.assertIn("warning:", result.stderr)

    def test_errors_fail_the_command(self):
        result = self.run_linter("dangling.cpp", "--warnings-as-errors")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count("[tbc-dangling-borrow]"), 3, result.stderr)
        self.assertIn("error:", result.stderr)

    def test_each_translation_unit_is_analyzed(self):
        result = self.run_linter("dangling.cpp", others=("annotation.cpp",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count("[tbc-dangling-borrow]"), 5, result.stderr)

    def test_plain_reference_returns_are_checked_too(self):
        result = self.run_linter("annotation.cpp")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count("[tbc-dangling-borrow]"), 2, result.stderr)

    def test_compiler_warnings_as_errors_do_not_hide_tbc_diagnostics(self):
        result = self.run_linter(
            "dangling.cpp", "--extra-arg=-Werror=return-stack-address",
        )
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count("[tbc-dangling-borrow]"), 3, result.stderr)

    def test_invalid_arguments_fail(self):
        result = subprocess.run(
            [str(BINARY), "--unknown-option"],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_invalid_cpp_does_not_produce_lifetime_guesses(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "invalid.cpp"
            source.write_text("const int &bad() { missing(); int local = 1; return local; }\n")
            result = subprocess.run(
                [str(BINARY), str(source), "--", "-std=c++23", "-Wno-return-stack-address"],
                capture_output=True, text=True, timeout=20,
            )
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("[tbc-", result.stderr)

    def test_compiler_errors_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "invalid.cpp"
            source.write_text("not valid C++;\n")
            result = subprocess.run(
                [str(BINARY), str(source), "--", "-std=c++23"],
                capture_output=True, text=True, timeout=20,
            )
        self.assertNotEqual(result.returncode, 0)


class PublicSignatureTest(unittest.TestCase):
    def compile_source(self, source, *options):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "signature.cpp"
            path.write_text('#include "tbc/view.hpp"\n#include <string_view>\n' + source)
            command = [str(COMPILER), "-std=c++23", f"-I{INCLUDE}", "-fsyntax-only", *options]
            if SYSROOT:
                command += ["-isysroot", SYSROOT]
            return subprocess.run(
                [*command, str(path)], capture_output=True, text=True, timeout=20,
            )

    def test_regions_and_aliases_are_preserved_in_the_ast(self):
        result = self.compile_source(
            'using signature_a = tbc::view<std::string_view, tbc::lt::a>;\n'
            'using signature_b = tbc::view<std::string_view, tbc::lt::b>;\n'
            'signature_a signatureExample(signature_a first, signature_b second) { return second; }\n',
            "-Xclang", "-ast-dump", "-Xclang", "-ast-dump-filter=signature",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("tbc::lt::a", result.stdout)
        self.assertIn("tbc::lt::b", result.stdout)
        self.assertIn("TemplateSpecializationType", result.stdout)
        self.assertIn("std::string_view", result.stdout)
        self.assertNotIn("AnnotateAttr", result.stdout)

    def test_elided_signature_is_ordinary_cpp(self):
        result = self.compile_source(
            'tbc::view<const int &> identity(tbc::view<const int &> renamed) { return renamed; }\n',
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_signature_types_are_rejected_by_the_compiler(self):
        invalid = {
            "not_a_region": 'tbc::view<std::string_view, int>',
            "parameter_name": 'tbc::view<std::string_view, "source">',
            "void_view": 'tbc::view<void>',
            "function_view": 'tbc::view<void()>',
        }
        for name, view in invalid.items():
            with self.subTest(name=name):
                result = self.compile_source(f"using invalid_view = {view};\n")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("error:", result.stderr)


if __name__ == "__main__":
    unittest.main()
