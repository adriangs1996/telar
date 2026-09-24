#!/usr/bin/env python3
"""Check that telar-client imports stay inside the package and its allowed modules."""
from __future__ import annotations

import argparse
from pathlib import Path
import re

TOKENS = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"|@(?:import|cInclude)\s*\(')
LITERAL = re.compile(r'\s*"([^"\\]+)"\s*\)')
ALLOWED_MODULES = {"std", "builtin", "model", "telar-core", "telar-lua", "lua-api"}
NATIVE_HEADERS = {("graphics/store.zig", "sys/stat.h"), ("resources/local_time.zig", "time.h")}


def calls(source, name):
    for token in TOKENS.finditer(source):
        if not token.group().startswith("@" + name):
            continue
        argument = LITERAL.match(source, token.end())
        if argument is None:
            raise ValueError("imports must use literal module or file paths")
        yield argument.group(1)


def imports(source):
    return calls(source, "import")


def libraries(root):
    """Standalone libraries under lib/, which any package may import."""
    folder = root.parent.parent / "lib"
    return {p.name for p in folder.iterdir() if (p / "root.zig").is_file()} if folder.is_dir() else set()


def violations(root):
    root = root.resolve()
    files = {p.relative_to(root).as_posix() for p in root.rglob("*.zig") if p.is_file()}
    errors = []
    for name in sorted(files):
        source = root / name
        if not source.resolve().is_relative_to(root):
            errors.append(f"{source}: source leaves telar-client")
            continue
        if source.resolve() != source:
            errors.append(f"{source}: source aliases another file")
            continue
        try:
            text = source.read_text()
            paths = list(imports(text))
            for header in calls(text, "cInclude"):
                if (name, header) not in NATIVE_HEADERS:
                    errors.append(f"{source}: forbidden native header {header}")
        except ValueError as error:
            errors.append(f"{source}: {error}")
            continue
        for imported in paths:
            if not imported.endswith(".zig"):
                if imported not in ALLOWED_MODULES | libraries(root):
                    errors.append(f"{source}: forbidden module {imported}")
                continue
            destination = (source.parent / imported).resolve()
            if Path(imported).is_absolute() or not destination.is_relative_to(root):
                errors.append(f"{source}: import leaves telar-client: {imported}")
                continue
            if destination.relative_to(root).as_posix() not in files:
                errors.append(f"{source}: missing import or incorrect case: {imported}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("src/client"))
    args = parser.parse_args()
    errors = violations(args.root)
    for error in errors:
        print(error)
    if not errors:
        print("telar-client module boundaries passed")
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
