"""Validate compile-only specifications and compare exact primary diagnostics.

Pending expectations are not successes: --mode all fails until every case matches.
No fixture is linked or executed, including examples containing undefined behavior.
"""

import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
from fnmatch import fnmatchcase
from pathlib import Path
import re
import subprocess
import sys

PROJECT = Path(__file__).resolve().parent.parent
REPOSITORY = PROJECT.parent.parent
CORPUS = Path(__file__).resolve().parent / "spec"
FIELD = re.compile(r"^// (CASE|PAIR|SOURCE|STATUS|CONTRACT|SCENARIO): (.+)$")
EXPECTED = re.compile(r"// expected-error \[(tbc-[a-z-]+)\]\s*$")
DIAGNOSTIC = re.compile(r"^(.+):(\d+):(\d+): (warning|error|fatal error): .*\[(tbc-[a-z-]+)\]$")


@dataclass
class Case:
    name: str
    source: Path
    start: int
    end: int
    fields: dict
    expected: Counter


def load_cases(directory=CORPUS, repository=REPOSITORY):
    cases = []
    for path in sorted(directory.glob("*.cpp")):
        fields = None
        expected = Counter()
        start = 0
        for number, line in enumerate(path.read_text().splitlines(), 1):
            field = FIELD.fullmatch(line)
            if field:
                key, value = field.groups()
                if key == "CASE":
                    if fields is not None:
                        raise ValueError(f"{path}:{number}: nested case")
                    fields, expected, start = {}, Counter(), number
                if fields is None or key in fields:
                    raise ValueError(f"{path}:{number}: misplaced or duplicate field {key}")
                fields[key] = value
            marker = EXPECTED.search(line)
            if marker:
                if fields is None:
                    raise ValueError(f"{path}:{number}: diagnostic outside a case")
                expected[number, marker[1]] += 1
            elif "expected-error" in line:
                raise ValueError(f"{path}:{number}: malformed diagnostic marker")
            if line == "// END CASE":
                required = {"CASE", "PAIR", "SOURCE", "STATUS", "CONTRACT", "SCENARIO"}
                if fields is None or fields.keys() != required:
                    raise ValueError(f"{path}:{number}: incomplete case metadata")
                if fields["STATUS"] not in {"implemented", "pending"}:
                    raise ValueError(f"{path}:{number}: invalid status")
                origin, separator, symbol = fields["SOURCE"].partition(" :: ")
                if not separator or not symbol or not (repository / origin).is_file():
                    raise ValueError(f"{path}:{number}: missing project provenance")
                cases.append(Case(fields["CASE"], path.resolve(), start, number, fields, expected))
                fields = None
        if fields is not None:
            raise ValueError(f"{path}: unterminated case")
    if not cases or len({case.name for case in cases}) != len(cases):
        raise ValueError("The corpus must contain cases with unique identifiers")
    pairs = defaultdict(set)
    for case in cases:
        pairs[case.fields["PAIR"]].add(bool(case.expected))
    if any(outcomes != {True, False} for outcomes in pairs.values()):
        raise ValueError("Every pair must contain both accepted and rejected examples")
    return cases


def compare_diagnostics(cases, output, source):
    actual = defaultdict(Counter)
    problems = []
    for line in output.splitlines():
        match = DIAGNOSTIC.fullmatch(line)
        if not match:
            continue
        file, number, _, severity, code = match.groups()
        number = int(number)
        owner = next((case for case in cases if case.start <= number <= case.end), None)
        if Path(file).resolve() != source.resolve() or owner is None:
            problems.append(f"Unassigned diagnostic: {line}")
        elif severity != "error":
            problems.append(f"Expected --warnings-as-errors severity: {line}")
        else:
            actual[owner.name][number, code] += 1
    return actual, problems


def has_foreign_errors(output):
    return any(
        re.match(r"^(?:(?:.+:\d+:\d+|\S+): )?(?:fatal )?error:", line) and not DIAGNOSTIC.fullmatch(line)
        for line in output.splitlines()
    )


def run(command):
    return subprocess.run(command, cwd=PROJECT, capture_output=True, text=True, timeout=40)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True)
    parser.add_argument("--linter", required=True)
    parser.add_argument("--sysroot", default="")
    parser.add_argument("--mode", choices=("validate", "implemented", "all"), default="validate")
    parser.add_argument("--case", default="*", help="Select case IDs with a shell-style pattern")
    options = parser.parse_args(argv)
    cases = load_cases()
    selected = {case.name for case in cases if fnmatchcase(case.name, options.case)}
    if not selected:
        raise ValueError(f"No specification cases match {options.case!r}")
    sources = {case.source for case in cases if case.name in selected}
    by_source = defaultdict(list)
    for case in cases:
        if case.source in sources:
            by_source[case.source].append(case)
    flags = ["-std=c++23", f"-I{PROJECT / 'include'}", "-Wno-return-stack-address"]
    if options.sysroot:
        flags += ["-isysroot", options.sysroot]
    failures = []
    matched = 0
    checked = 0
    for source, file_cases in by_source.items():
        compiled = run([options.compiler, *flags, "-fsyntax-only", str(source)])
        if compiled.returncode:
            failures.append(f"Invalid C++ fixture {source.name}:\n{compiled.stderr}")
            continue
        if options.mode == "validate":
            continue
        result = run([options.linter, "--warnings-as-errors", str(source), "--", *flags, "-ferror-limit=0"])
        actual, problems = compare_diagnostics(file_cases, result.stderr, source)
        failures.extend(problems)
        # Non-tbc compiler errors, crashes and timeouts must not look like missing rules.
        foreign_error = has_foreign_errors(result.stderr)
        has_diagnostics = any(actual.values())
        expected_exit = 1 if has_diagnostics else 0
        if result.returncode != expected_exit or foreign_error:
            failures.append(f"Invalid linter invocation for {source.name}:\n{result.stderr}")
            continue
        for case in file_cases:
            if case.name not in selected:
                continue
            if options.mode == "implemented" and case.fields["STATUS"] == "pending":
                continue
            checked += 1
            observed = actual[case.name]
            if observed == case.expected:
                matched += 1
            else:
                missing = list((case.expected - observed).elements())
                unexpected = list((observed - case.expected).elements())
                failures.append(f"{case.name} [{case.fields['STATUS']}]: missing={missing}, unexpected={unexpected}")
    pending = sum(case.fields["STATUS"] == "pending" for case in cases)
    print(f"Corpus: {len(cases)} cases, {len(selected)} selected, {len(by_source)} compile-only files, {pending} explicitly pending")
    if options.mode != "validate":
        print(f"Diagnostics matched: {matched}/{checked} checked cases; mode={options.mode}")
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
