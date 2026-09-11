#!/usr/bin/env python3
"""Compare named tests advertised by two native Zig 0.16 test builds.

Build each checkout with `zig build test --verbose`, saving stdout and stderr.
This queries those executables for metadata; it does not rerun their tests.
Names are compared without their changed file/type qualification. Repetition
counts are reported separately: removing a barrel can remove duplicate runs.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import shlex
import struct
import subprocess


def metadata(data):
    offset = 0
    found = None
    while offset < len(data):
        if len(data) - offset < 8:
            raise ValueError("truncated Zig server header")
        tag, size = struct.unpack_from("<II", data, offset)
        offset += 8
        body = data[offset:offset + size]
        offset += size
        if len(body) != size:
            raise ValueError("truncated Zig server message")
        if tag != 3:
            continue
        if found is not None or len(body) < 8:
            raise ValueError("duplicate or truncated test metadata")
        strings_len, count = struct.unpack_from("<II", body)
        if len(body) != 8 + count * 8 + strings_len:
            raise ValueError("invalid test metadata length")
        indices = struct.unpack_from("<" + "I" * count, body, 8)
        strings = body[8 + count * 8:]
        found = []
        for index in indices:
            if index >= len(strings):
                raise ValueError("invalid test name offset")
            end = strings.find(b"\0", index)
            if end == -1:
                raise ValueError("unterminated test name")
            found.append(strings[index:end].decode("utf-8"))
    if found is None:
        raise ValueError("test executable did not advertise metadata")
    return found


def executable_paths(root, log):
    root = root.resolve()
    paths = set()
    for line in log.read_text().splitlines():
        if "--listen=-" not in line:
            continue
        try:
            tokens = shlex.split(line)
        except ValueError:
            continue
        for token in tokens:
            if not token.endswith("/test") or ".zig-cache/o/" not in token:
                continue
            if token.startswith(".../.zig-cache/o/"):
                token = token[4:]
            executable = (root / token).resolve()
            relative = executable.relative_to(root)
            if relative.parts[:2] != (".zig-cache", "o"):
                raise ValueError("test executable is outside the checkout cache")
            paths.add(relative.as_posix())
    if not paths:
        raise ValueError("no native test executables found; build with --verbose")
    return sorted(paths)


def inventory(root, log):
    binaries = []
    tests = []
    for path in executable_paths(root, log):
        result = subprocess.run(
            [str(root.resolve() / path), "--listen=-"],
            input=struct.pack("<IIII", 4, 0, 0, 0),  # query_test_metadata, exit
            capture_output=True, timeout=30, check=True, cwd=root,
        )
        names = metadata(result.stdout)
        binaries.append({"path": path, "names": names})
        tests.extend(names)
    return {"binaries": binaries, "tests": tests}


def named(tests):
    return Counter(name.rsplit(".test.", 1)[1] for name in tests if ".test." in name)


def compare(before, after):
    baseline = named(before["tests"])
    candidate = named(after["tests"])
    return {
        "baseline": before,
        "candidate": after,
        "baseline_unique_names": len(baseline),
        "candidate_unique_names": len(candidate),
        "missing_names": sorted(baseline.keys() - candidate.keys()),
        "added_names": sorted(candidate.keys() - baseline.keys()),
        "fewer_repetitions": dict(sorted((baseline - candidate).items())),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for version in ("baseline", "candidate"):
        parser.add_argument(f"--{version}-root", type=Path, required=True)
        parser.add_argument(f"--{version}-log", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = compare(
        inventory(args.baseline_root, args.baseline_log),
        inventory(args.candidate_root, args.candidate_log),
    )
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key not in {"baseline", "candidate", "fewer_repetitions"}}, indent=2))
    return bool(result["missing_names"])


if __name__ == "__main__":
    raise SystemExit(main())
