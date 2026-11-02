#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import struct
import tempfile

from check_legacy_checkpoints import run_runtime


def main():
    parser = argparse.ArgumentParser(description="Exercise restored identifier counters at exhaustion")
    for name in ("zig", "cpp", "probe", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    arguments = parser.parse_args()
    binaries = {name: getattr(arguments, name).resolve() for name in ("zig", "cpp", "probe")}
    report = {"binaries": {name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for name, path in binaries.items()}, "cases": []}
    for counter, name in enumerate(("workspace", "tab", "pane", "generation")):
        for value in (2**64 - 2, 2**64 - 1):
            counters = [1, 1, 1, 1]
            counters[counter] = value
            case = {"counter": name, "value": value, "implementations": {}}
            for implementation in ("zig", "cpp"):
                with tempfile.TemporaryDirectory(prefix="telar-identity-boundaries-", dir="/tmp") as temporary:
                    root = Path(temporary)
                    checkpoint = root / "session.ckpt"
                    checkpoint.write_bytes(b"TELARCKP" + struct.pack("<HQQQQB", 10, *counters, 0))
                    checkpoint.chmod(0o600)
                    result = {"passed": True}
                    try:
                        run_runtime(binaries[implementation], binaries["probe"], root, [], "identity-boundaries")
                        saved_counters = struct.unpack_from("<QQQQ", checkpoint.read_bytes(), 10)
                        result["checkpoint_counters"] = saved_counters
                        if 0 in saved_counters:
                            run_runtime(binaries[implementation], binaries["probe"], root, [], "empty")
                            result["restart_discards_exhausted_checkpoint"] = True
                        diagnostics = (root / "server.log").read_text()
                        assert "ERROR: AddressSanitizer" not in diagnostics and "runtime error:" not in diagnostics
                    except Exception as error:
                        result.update(passed=False, error=str(error))
                    output = root / "expected"
                    result["responses"] = output.read_text().splitlines() if output.exists() else []
                    case["implementations"][implementation] = result
            case["equivalent"] = all(result["passed"] for result in case["implementations"].values()) and case["implementations"]["zig"]["responses"] == case["implementations"]["cpp"]["responses"]
            report["cases"].append(case)
            print(name, value, "equivalent" if case["equivalent"] else "different", flush=True)
    report["passed"] = all(case["equivalent"] for case in report["cases"])
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
