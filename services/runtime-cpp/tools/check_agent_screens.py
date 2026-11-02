#!/usr/bin/env python3
import argparse
import ctypes
import hashlib
import io
import itertools
import json
from pathlib import Path
import shutil
import subprocess
import tarfile


class Input(ctypes.Structure):
    _fields_ = [("bytes", ctypes.c_char_p), ("length", ctypes.c_size_t), ("columns", ctypes.c_uint16), ("rows", ctypes.c_uint16), ("chunk", ctypes.c_uint16), ("provider", ctypes.c_uint8), ("manifests", ctypes.c_uint8)]


def fingerprint(path):
    return {"path": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def build(root, arguments):
    artifacts = arguments.artifacts.resolve()
    reference = artifacts / "reference"
    reference.mkdir(parents=True, exist_ok=True)
    if not arguments.reuse_reference:
        paths = ["src/core", "lib/keyinput", "src/backend/history/prompt_scan.zig", "src/backend/history/codex_screen.zig", "src/backend/history/cursor_screen.zig", "src/backend/history/ScreenRow.zig", "build.zig.zon"]
        archived = subprocess.check_output(["git", "archive", arguments.reference, *paths], cwd=root.parents[1])
        with tarfile.open(fileobj=io.BytesIO(archived)) as archive:
            archive.extractall(reference, filter="data")
        shutil.copy2(root / "tests/screen_reference.zig", reference / "oracle.zig")
        shutil.copy2(root / "tests/screen_reference_build.zig", reference / "build.zig")
        subprocess.run([arguments.zig, "build", "-Doptimize=ReleaseFast", "-j3"], cwd=reference, check=True)
        shutil.copy2(reference / "zig-out/lib/libscreen-reference.dylib", artifacts / "zig.dylib")

    build_directory = arguments.build_dir.resolve()
    cache = {}
    for line in (build_directory / "CMakeCache.txt").read_text().splitlines():
        if "=" in line and ":" in line and not line.startswith(("//", "#")):
            name, value = line.split("=", 1)
            cache[name.split(":", 1)[0]] = value
    subprocess.run([cache["CMAKE_CXX_COMPILER"], "-std=c++23", "-O3", "-dynamiclib", "-DTELAR_DEBUG=0", "-DTELAR_DIAGNOSTICS=0", "-I", str(root), "-I", str(root.parents[1] / "dlls/telar-client/include"), "-I", str(build_directory / "generated"), "-I", cache["GHOSTTY_VT_INCLUDE_DIR"], str(root / "tests/screen_oracle.cpp"), str(build_directory / "libruntime-core.a"), cache["GHOSTTY_VT_LIBRARY"], "-o", str(artifacts / "cpp.dylib")], check=True)
    return artifacts


def position(row, column, text):
    return f"\x1b[{row + 1};{column + 1}H{text}"


def fixtures():
    for column, contents, hidden in itertools.product([0, 1, 7, 8, 9], ["❯ ", "❯ text", "❯ \x1b[2mdim\x1b[0m", "❯\u00a0"], [False, True]):
        text = "\x1b]0;✳ Idle\x07" + ("\x1b[?25l" if hidden else "\x1b[?25h") + position(22, 0, contents) + position(22, column, "")
        yield ("claude-cursor-cell", 1, text, 80, 24, 1)

    for title, hidden, distance, style, row in itertools.product(["", "✳ Idle", "◐ Working", "◑ Working"], [False, True], [0, 1, 7, 8, 9], ["", "\x1b[7m", "\x1b[41m", "\x1b[48;2;1;2;3m"], [0, 11, 12, 22, 23]):
        prompt = "❯" + " " * distance
        text = f"\x1b]0;{title}\x07" + ("\x1b[?25l" if hidden else "\x1b[?25h") + position(row, 0, prompt + style + " " + "\x1b[0m")
        text += position(row, len(prompt), "")
        yield ("claude-cursor", 1, text, 80, 24, 1)

    for title, first, second, hidden in itertools.product(["", "✳ Idle", "◐ Working"], ["", "draft", "\x1b[2mplaceholder\x1b[0m", "\u00a0", "\x1b[7m \x1b[0m"], ["", "draft", "\x1b[2mplaceholder\x1b[0m", "\x1b[7m \x1b[0m"], [False, True]):
        text = f"\x1b]0;{title}\x07" + ("\x1b[?25l" if hidden else "\x1b[?25h") + position(20, 0, "❯ " + first) + position(22, 0, "❯ " + second)
        yield ("claude-multiple-prompts", 1, text, 80, 24, 1)

    for heading, clock, column, hidden, manifests in itertools.product(["Working", "Thinking", "Reconnecting", "Compacting", "• Other", "⠞ Other", "Unknown"], ["1s)", "12m)", "3h)", "s)", "1.2s)", "1x)", "01s)", "1s"], [0, 1, 2], [False, True], [0, 1]):
        text = ("\x1b[?25l" if hidden else "\x1b[?25h") + position(20, 0, f"{heading} ({clock}") + position(22, column, "› Ask Codex to do anything") + position(22, column + 2, "")
        yield ("codex-status", 2, text, 80, 24, manifests)

    for rows, composer, cursor, indent, rule in itertools.product([24, 40], [0, 7, 8, 22], [0, 1, 2], [0, 1, 2, 3], [False, True]):
        text = position(max(composer - 2, 0), 0, "Working (1s)")
        if rule and composer > 0:
            text += position(composer - 1, 0, "─")
        text += position(composer, 0, "› draft")
        if cursor:
            text += position(min(rows - 1, composer + cursor), indent, "continuation")
        text += position(min(rows - 1, composer + cursor), indent, "")
        yield ("codex-continuation", 2, text, 80, rows, 1)

    for column, distance, spinner, label, placeholder in itertools.product([0, 1, 3, 4], [0, 1, 5, 6, 7], ["⠞", "•", "⠀", "⣿"], ["Working", "working", "1working", ""], ["Add a follow-up", "Plan, search, build anything", "draft", "draft ctrl+c to stop"]):
        text = position(22 - distance, 0, spinner + " " + label) + position(22, column, "→ " + placeholder)
        yield ("cursor-spinner", 4, text, 80, 24, 1)

    for column in [1022, 1023, 1024, 1025]:
        text = position(0, 0, "Working (1s)") + position(2, column, "─") + position(4, 0, "› ")
        yield ("codex-row-boundary", 2, text, 1030, 6, 1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", required=True, type=Path)
    parser.add_argument("--artifacts", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--reference", default="23c87dfcb14d0a0524808c4ca46c3d9d17056ad1")
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--reuse-reference", action="store_true")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    artifacts = build(root, arguments)
    libraries = [ctypes.CDLL(str(artifacts / (name + ".dylib"))) for name in ["zig", "cpp"]]
    for library in libraries:
        library.scan_screen.argtypes = [ctypes.POINTER(Input)]
        library.scan_screen.restype = ctypes.c_uint32
    failures = []
    count = 0
    for name, provider, text, columns, rows, manifests in fixtures():
        data = text.encode()
        for chunk in [0, 1, 7]:
            request = Input(data, len(data), columns, rows, chunk, provider, manifests)
            reference, candidate = [library.scan_screen(ctypes.byref(request)) for library in libraries]
            count += 1
            if reference != candidate or reference & 0x80000000:
                failures.append({"name": name, "provider": provider, "input": text, "columns": columns, "rows": rows, "chunk": chunk, "manifests": manifests, "zig": reference, "cpp": candidate})
    report = {"reference": arguments.reference, "cases": count, "failures": failures, "passed": not failures, "binaries": {name: fingerprint(artifacts / (name + ".dylib")) for name in ["zig", "cpp"]}}
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"cases": count, "failures": len(failures), "passed": report["passed"]}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
