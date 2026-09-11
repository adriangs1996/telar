#!/usr/bin/env python3
"""Check the shared client's module and public-capability boundaries."""
from __future__ import annotations

import argparse
from pathlib import Path
import re

TOKENS = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"|@(?:import|cInclude)\s*\(')
LITERAL = re.compile(r'\s*"([^"\\]+)"\s*\)')
ALLOWED_MODULES = {"std", "builtin", "telar-core"}


def calls(source, name):
    for token in TOKENS.finditer(source):
        if not token.group().startswith("@" + name):
            continue
        argument = LITERAL.match(source, token.end())
        if argument is None:
            raise ValueError("imports must use literal module or capability paths")
        yield argument.group(1)


def imports(source):
    return calls(source, "import")


def capability(path, root):
    directory = path.parent
    while directory != root:
        if directory.name != "tests" and (directory / "root.zig").is_file():
            return directory
        directory = directory.parent
    return root


def violations(root):
    root = root.resolve()
    errors = []
    if not (root / "root.zig").is_file():
        return [f"{root}: missing client root"]
    for source in sorted(root.rglob("*.zig")):
        try:
            text = source.read_text()
            paths = list(imports(text))
            for header in calls(text, "cInclude"):
                if source.relative_to(root).as_posix() != "graphics/store.zig" or header != "sys/stat.h":
                    errors.append(f"{source}: forbidden native header {header}")
        except ValueError as error:
            errors.append(f"{source}: {error}")
            continue
        for imported in paths:
            if not imported.endswith(".zig"):
                if imported not in ALLOWED_MODULES:
                    errors.append(f"{source}: forbidden module {imported}")
                continue
            destination = (source.parent / imported).resolve()
            if not destination.is_relative_to(root):
                errors.append(f"{source}: import leaves telar-client: {imported}")
            elif not destination.is_file():
                errors.append(f"{source}: missing import {imported}")
            elif destination.name != "root.zig" and capability(source, root) != capability(destination, root):
                errors.append(f"{source}: import capability root instead of {imported}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("src/client"))
    args = parser.parse_args()
    errors = violations(args.root)
    for error in errors:
        print(error)
    if not errors:
        print("telar-client module and capability boundaries passed")
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
