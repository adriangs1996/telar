#!/usr/bin/env python3
"""Keep packages from republishing library members.

A library under lib/ is imported by name wherever it is used. A telar file
that declares `pub const X = library.member;`, directly or through a private
alias, turns itself into a facade and hides which library its consumers
depend on.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re

IMPORT = re.compile(r'^[ \t]*const (\w+) = @import\("([^"]+)"\);', re.M)
ALIAS = re.compile(r"^[ \t]*const (\w+) = (\w+)(?:\.\w+)+;", re.M)
PUBLIC = re.compile(r"^[ \t]*pub const (\w+) = (\w+)(?:\.\w+)*;", re.M)
SOURCE_ROOTS = ("src", "benchmarks")


def libraries(root):
    folder = root / "lib"
    return {p.name for p in folder.iterdir() if (p / "root.zig").is_file()} if folder.is_dir() else set()


def library_aliases(text, names):
    aliases = {m.group(1) for m in IMPORT.finditer(text) if m.group(2) in names}
    grown = True
    while grown:
        grown = False
        for match in ALIAS.finditer(text):
            if match.group(2) in aliases and match.group(1) not in aliases:
                aliases.add(match.group(1))
                grown = True
    return aliases


def violations(root):
    root = root.resolve()
    names = libraries(root)
    errors = []
    for folder in SOURCE_ROOTS:
        for source in sorted((root / folder).rglob("*.zig")):
            text = source.read_text()
            aliases = library_aliases(text, names)
            for match in PUBLIC.finditer(text):
                if match.group(2) in aliases:
                    line = text.count("\n", 0, match.start()) + 1
                    errors.append(f"{source}:{line}: import the library instead of re-exporting it: {match.group(0).strip()}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    errors = violations(args.root)
    if errors:
        print("\n".join(errors))
        return 1
    print("Library re-exports passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
