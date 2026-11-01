"""Keep missing diagnostics, false positives, and invalid fixtures distinguishable."""

from collections import Counter
from pathlib import Path
import re
import tempfile
import unittest

import spec_runner


class SpecRunnerTest(unittest.TestCase):
    def setUp(self):
        self.source = Path("/fixture/example.cpp")
        self.case = spec_runner.Case(
            "example", self.source, 1, 10, {}, Counter({(5, "tbc-dangling-borrow"): 1}),
        )

    def test_exact_location_and_code_match(self):
        output = f"{self.source}:5:3: error: escaped [tbc-dangling-borrow]\n"
        actual, problems = spec_runner.compare_diagnostics([self.case], output, self.source)
        self.assertFalse(problems)
        self.assertEqual(actual["example"], self.case.expected)

    def test_missing_diagnostic_does_not_pass(self):
        actual, problems = spec_runner.compare_diagnostics([self.case], "", self.source)
        self.assertFalse(problems)
        self.assertNotEqual(actual["example"], self.case.expected)

    def test_wrong_location_does_not_pass(self):
        output = f"{self.source}:6:3: error: escaped [tbc-dangling-borrow]\n"
        actual, _ = spec_runner.compare_diagnostics([self.case], output, self.source)
        self.assertNotEqual(actual["example"], self.case.expected)

    def test_duplicate_diagnostics_do_not_pass(self):
        line = f"{self.source}:5:3: error: escaped [tbc-dangling-borrow]\n"
        actual, _ = spec_runner.compare_diagnostics([self.case], line * 2, self.source)
        self.assertNotEqual(actual["example"], self.case.expected)

    def test_unexpected_diagnostic_on_accepted_case_does_not_pass(self):
        self.case.expected = Counter()
        output = f"{self.source}:5:3: error: escaped [tbc-dangling-borrow]\n"
        actual, _ = spec_runner.compare_diagnostics([self.case], output, self.source)
        self.assertNotEqual(actual["example"], self.case.expected)

    def test_notes_are_not_primary_errors(self):
        output = f"{self.source}:5:3: note: declaration is here\n"
        actual, problems = spec_runner.compare_diagnostics([self.case], output, self.source)
        self.assertFalse(problems)
        self.assertFalse(actual)

    def test_header_diagnostics_are_not_silently_dropped(self):
        output = "/fixture/support.hpp:5:3: error: escaped [tbc-dangling-borrow]\n"
        _, problems = spec_runner.compare_diagnostics([self.case], output, self.source)
        self.assertTrue(problems)

    def test_wrong_severity_is_not_accepted(self):
        output = f"{self.source}:5:3: warning: escaped [tbc-dangling-borrow]\n"
        _, problems = spec_runner.compare_diagnostics([self.case], output, self.source)
        self.assertTrue(problems)

    def test_error_limit_failure_is_not_a_missing_rule(self):
        output = "fatal error: too many errors emitted, stopping now [-ferror-limit=]\n"
        self.assertTrue(spec_runner.has_foreign_errors(output))

    def test_source_excerpt_is_not_a_compiler_error(self):
        output = '   5 | observe("prefix: error: text");\n'
        self.assertFalse(spec_runner.has_foreign_errors(output))

    def test_tbc_errors_are_not_compiler_failures(self):
        output = f"{self.source}:5:3: error: escaped [tbc-dangling-borrow]\n"
        self.assertFalse(spec_runner.has_foreign_errors(output))

    def test_metadata_has_provenance_and_both_outcomes(self):
        cases = spec_runner.load_cases()
        self.assertTrue(any(case.fields["STATUS"] == "pending" for case in cases))
        self.assertTrue(any(case.fields["STATUS"] == "implemented" for case in cases))
        self.assertTrue(all(case.fields["CONTRACT"] and case.fields["SCENARIO"] for case in cases))

    def test_fixtures_use_the_public_contract_api(self):
        support = (spec_runner.CORPUS / "support.hpp").read_text()
        self.assertIn('#include "tbc/view.hpp"', support)
        self.assertIn("tbc::view<", support)
        self.assertIn("tbc::lt::a", support)
        self.assertIn("tbc::lt::b", support)
        for path in sorted(spec_runner.CORPUS.iterdir()):
            if path.suffix not in {".cpp", ".hpp"}:
                continue
            with self.subTest(source=path.name):
                text = path.read_text()
                self.assertIsNone(re.search(r"\bTBC_[A-Z_]+\s*\(", text))
                self.assertNotIn("clang::annotate", text)
                self.assertNotIn("function_contract", text)
                self.assertNotIn("type_contract", text)
                self.assertNotIn("constructor_contract", text)
                self.assertNotIn("destructor_contract", text)
                self.assertNotIn("tbc::parameter<", text)
                self.assertNotIn("tbc::from<", text)

    def test_unterminated_case_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "fixture.cpp").write_text("// CASE: unfinished\n")
            with self.assertRaisesRegex(ValueError, "unterminated"):
                spec_runner.load_cases(root, root)

    def test_malformed_marker_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "fixture.cpp").write_text("// CASE: unfinished\n// expected-error broken\n")
            with self.assertRaisesRegex(ValueError, "malformed"):
                spec_runner.load_cases(root, root)


if __name__ == "__main__":
    unittest.main()
