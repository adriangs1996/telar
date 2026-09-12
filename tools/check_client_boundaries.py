#!/usr/bin/env python3
"""Check shared-client imports against explicit public capability files."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re

TOKENS = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"|@(?:import|cInclude)\s*\(')
LITERAL = re.compile(r'\s*"([^"\\]+)"\s*\)')
ALLOWED_MODULES = {"std", "builtin", "telar-core", "telar-lua", "lua-api"}


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


def relative_name(value):
    if not isinstance(value, str):
        raise ValueError("boundary paths must be strings")
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or path.as_posix() != value:
        raise ValueError(f"boundary path must be canonical and relative: {value}")
    return value


def policy(root):
    try:
        value = json.loads((root / "capabilities.json").read_text())
    except (OSError, ValueError) as error:
        raise ValueError(f"missing or invalid capability policy: {error}") from error
    expected = {"entrypoint", "capabilities", "public", "assembly_imports"}
    if not isinstance(value, dict) or set(value) != expected:
        raise ValueError("capability policy must declare entrypoint, capabilities, public and assembly_imports")
    relative_name(value["entrypoint"])
    for key in ("capabilities", "public", "assembly_imports"):
        if not isinstance(value[key], list):
            raise ValueError(f"{key} must be a list")
        for name in value[key]:
            relative_name(name)
        if len(value[key]) != len(set(value[key])):
            raise ValueError(f"duplicate {key} entry")
    if "." not in value["capabilities"]:
        raise ValueError("capabilities must declare the package owner '.'")
    directories = {".", *(p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_dir())}
    for name in value["capabilities"]:
        directory = root / name
        if name not in directories or not directory.resolve().is_relative_to(root):
            raise ValueError(f"missing, incorrectly cased or escaped capability directory: {name}")
    files = {p.relative_to(root).as_posix() for p in root.rglob("*.zig") if p.is_file()}
    for name in files:
        path = Path(name)
        if path.parent != Path(".") and capability(path, value["capabilities"]) == ".":
            raise ValueError(f"source directory must declare a capability: {name}")
    for name in [value["entrypoint"], *value["public"], *value["assembly_imports"]]:
        if name not in files or not (root / name).resolve().is_relative_to(root):
            raise ValueError(f"missing or escaped public/assembly file: {name}")
    return value, files


def capability(path, directories):
    for parent in path.parents:
        name = parent.as_posix()
        if name in directories:
            return name
    raise ValueError(f"no capability owner for {path}")


def violations(root):
    root = root.resolve()
    try:
        rules, files = policy(root)
    except ValueError as error:
        return [f"{root}: {error}"]
    errors = []
    directories = set(rules["capabilities"])
    public = set(rules["public"])
    assembly = set(rules["assembly_imports"])
    for name in sorted(files):
        source = root / name
        if not source.resolve().is_relative_to(root):
            errors.append(f"{source}: source leaves telar-client")
            continue
        if source.resolve() != source:
            errors.append(f"{source}: source aliases another capability file")
            continue
        try:
            text = source.read_text()
            paths = list(imports(text))
            for header in calls(text, "cInclude"):
                if name != "graphics/store.zig" or header != "sys/stat.h":
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
            if Path(imported).is_absolute() or not destination.is_relative_to(root):
                errors.append(f"{source}: import leaves telar-client: {imported}")
                continue
            target = destination.relative_to(root).as_posix()
            if target not in files:
                errors.append(f"{source}: missing import or incorrect case: {imported}")
            elif capability(Path(name), directories) != capability(Path(target), directories):
                if target not in public and not (name == rules["entrypoint"] and target in assembly):
                    errors.append(f"{source}: import declared public capability file instead of {imported}")
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
