import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Compare exact reservation, completion, cancellation and exhaustion with the original Zig sources")
    parser.add_argument("--domain", choices=("capture", "catalog"), default="capture")
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    options.output.mkdir(parents=True, exist_ok=False)
    receipt = {"binaries": {}, "executions": {}}
    traces = {}
    for name, executable in (("cpp", options.cpp), ("zig", options.zig)):
        executable = executable.resolve()
        receipt["binaries"][name] = {"path": str(executable), "sha256": digest(executable)}
        path = options.output / (name + ".bin")
        with path.open("wb") as output, (options.output / (name + ".stderr")).open("wb") as error:
            result = subprocess.run([str(executable)], stdout=output, stderr=error)
        receipt["executions"][name] = {"exit_code": result.returncode, "bytes": path.stat().st_size, "sha256": digest(path)}
        (options.output / "results.json").write_text(json.dumps(receipt, indent=2))
        result.check_returncode()
        traces[name] = path.read_bytes()
    records, fields, outcomes = (65536, 13, 9) if options.domain == "capture" else (16384, 16, 7)
    record = struct.Struct("<" + str(fields) + "Q")
    assert len(traces["cpp"]) == records * record.size, "Incomplete C++ trace"
    assert traces["cpp"] == traces["zig"], "Original and port observations differ"
    counts = Counter(value[5 if options.domain == "capture" else 3] for value in record.iter_unpack(traces["cpp"]))
    assert set(counts) == set(range(outcomes)), "The deterministic trace must exercise every outcome"
    receipt.update({"domain": options.domain, "records": records, "observed_outcomes": dict(sorted(counts.items())), "byte_exact": True})
    (options.output / "results.json").write_text(json.dumps(receipt, indent=2))
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
