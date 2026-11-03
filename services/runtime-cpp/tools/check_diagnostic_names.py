#!/usr/bin/env python3
import argparse
import ctypes
import hashlib
import itertools
import json
from pathlib import Path
import random
import shutil
import subprocess


def fingerprint(path):
    return {"path": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifacts", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--reference", default="23c87dfcb14d0a0524808c4ca46c3d9d17056ad1")
    parser.add_argument("--compiler", default="clang++")
    parser.add_argument("--zig", default="zig")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    artifacts = arguments.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    reference = subprocess.check_output(["git", "show", f"{arguments.reference}:src/core/DiagnosticLogName.zig"], cwd=root)
    (artifacts / "DiagnosticLogName.zig").write_bytes(reference)
    shutil.copy2(root / "tests/diagnostic_name_reference.zig", artifacts / "oracle.zig")
    subprocess.run([arguments.zig, "build-lib", "-dynamic", "-O", "ReleaseFast", str(artifacts / "oracle.zig"), "-femit-bin=" + str(artifacts / "zig.dylib")], check=True)
    subprocess.run([arguments.compiler, "-std=c++23", "-O3", "-dynamiclib", "-I", str(root), "-I", str(root.parents[1] / "dlls/telar-client/include"), "-I", str(root.parents[1] / "dlls/telar-base/include"), "-I", str(root.parents[1] / "dlls/telar-lua/include"), "-I", str(root.parents[1] / "dlls/telar-platform/include"), "-I", str(root.parents[1] / "dlls/telar-plugins/include"), "-I", str(root.parents[1] / "dlls/telar-config/include"), str(root / "tests/diagnostic_name_oracle.cpp"), "-o", str(artifacts / "cpp.dylib")], check=True)
    libraries = [ctypes.CDLL(str(artifacts / name)) for name in ["zig.dylib", "cpp.dylib"]]
    for library in libraries:
        library.classify_name.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        library.classify_name.restype = ctypes.c_uint64

    cases = {b"", b"runtime.log", b"runtime.start.log"}
    processes = ["", "0", "1", "42", "00042", "4294967295", "4294967296", "2147483648", "-1", "+1", "_42", "42_", "4_2", "4__2", "0_0", "4 2", "42x", "0x42", "0" * 1000 + "42"]
    for endpoint, role, process, suffix in itertools.product(["", "a", "a.sock", "a.runtime-42.log", "x" * 1024], ["runtime", "client", "worker", ""], processes, [".log", ".log.1", ".log.2", "", ".log.1.1"]):
        cases.add(f"{endpoint}.{role}-{process}{suffix}".encode())
    generator = random.Random(9471)
    corpus = tuple(sorted(cases))
    for _ in range(10000):
        value = bytearray(generator.choice(corpus)[:256])
        if value:
            value[generator.randrange(len(value))] = generator.randrange(256)
        cases.add(bytes(value))

    failures = []
    for name in sorted(cases):
        reference_result, candidate_result = [library.classify_name(name, len(name)) for library in libraries]
        if reference_result != candidate_result:
            failures.append({"name_hex": name.hex(), "zig": reference_result, "cpp": candidate_result})
    report = {"reference": arguments.reference, "source_sha256": hashlib.sha256(reference).hexdigest(), "binaries": {name: fingerprint(artifacts / (name + ".dylib")) for name in ["zig", "cpp"]}, "cases": len(cases), "failures": failures, "passed": not failures}
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ["cases", "passed"]}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
