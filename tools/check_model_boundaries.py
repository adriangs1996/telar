#!/usr/bin/env python3
"""Keep shared values independent of clients and host services."""
from __future__ import annotations

import argparse
from pathlib import Path
import re

from check_client_boundaries import calls, imports

ALLOWED_MODULES = {"std", "builtin", "telar-core"}
MODEL_LIBRARIES = re.compile(r"pub const libraries = \[_\]\[\]const u8\{([^}]*)\};")
SOURCE_ROOTS = ("src", "examples", "benchmarks", "test", "build")


def model_libraries(root):
    """The libraries `build/model.zig` gives the model, the one list of them."""
    build = root / "build/model.zig"
    match = MODEL_LIBRARIES.search(build.read_text()) if build.is_file() else None
    return set(re.findall(r'"([^"]+)"', match.group(1))) if match else set()


def violations(root):
    root = root.resolve()
    allowed = ALLOWED_MODULES | model_libraries(root)
    model = root / "src/model"
    files = [p for folder in SOURCE_ROOTS for p in (root / folder).rglob("*.zig")]
    files.extend(root.glob("*.zig"))
    model_files = {p.relative_to(model).as_posix() for p in model.rglob("*.zig")}
    errors = []
    if "model.zig" not in model_files:
        return ["missing model entrypoint: src/model/model.zig"]
    for source in sorted(files):
        inside = source.is_relative_to(model)
        try:
            text = source.read_text()
            for path in imports(text):
                if path.endswith(".zig"):
                    target = (source.parent / path).resolve()
                    if inside:
                        if not target.is_relative_to(model):
                            errors.append(f"{source}: model import escapes its module: {path}")
                        elif target.relative_to(model).as_posix() not in model_files:
                            errors.append(f"{source}: missing or incorrectly cased model file: {path}")
                    elif target.is_relative_to(model):
                        errors.append(f'{source}: consume the public @import("model") API: {path}')
                elif inside and path not in allowed:
                    errors.append(f"{source}: forbidden model dependency: {path}")
                elif path == "model" and any(source.is_relative_to(root / "src" / lower) for lower in ("core", "lua")):
                    errors.append(f"{source}: reverse dependency on model")
            if inside and list(calls(text, "cInclude")):
                errors.append(f"{source}: native services belong outside model")
            if inside and source.resolve() != source:
                errors.append(f"{source}: source aliases another file")
        except (OSError, ValueError) as error:
            errors.append(f"{source}: {error}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    errors = violations(args.root)
    if errors:
        print("\n".join(errors))
        return 1
    print("Shared model boundaries passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
