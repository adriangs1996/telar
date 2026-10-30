import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess


FIT_COUNT = 16384
RECTANGLES = 8


def main():
    parser = argparse.ArgumentParser(description="Compare exact original sizing and premultiplied rectangular preview pixels")
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    options.output.mkdir(parents=True, exist_ok=False)
    results = {"binaries": {}, "executions": {}}
    outputs = {}
    for name, executable in (("cpp", options.cpp.resolve()), ("zig", options.zig.resolve())):
        results["binaries"][name] = {"path": str(executable), "sha256": hashlib.sha256(executable.read_bytes()).hexdigest()}
        trace = options.output / (name + ".bin")
        with trace.open("wb") as output, (options.output / (name + ".stderr")).open("wb") as error:
            process = subprocess.run([str(executable)], stdout=output, stderr=error)
        data = trace.read_bytes()
        results["executions"][name] = {"exit_code": process.returncode, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        (options.output / "results.json").write_text(json.dumps(results, indent=2))
        process.check_returncode()
        outputs[name] = data
    assert outputs["cpp"] == outputs["zig"], "Original and port preview observations differ"
    data = outputs["cpp"]
    fit_bytes = FIT_COUNT * struct.calcsize("<4Q")
    assert len(data) >= fit_bytes, "Incomplete sizing trace"
    offset = fit_bytes
    shapes = []
    for _ in range(RECTANGLES):
        source_width, source_height, width, height = struct.unpack_from("<4Q", data, offset)
        offset += struct.calcsize("<4Q")
        byte_count = width * height * 4
        assert len(data) - offset >= byte_count, "Incomplete rectangle trace"
        shapes.append({"source": [source_width, source_height], "destination": [width, height], "rgba_bytes": byte_count, "sha256": hashlib.sha256(data[offset:offset + byte_count]).hexdigest()})
        offset += byte_count
    assert offset == len(data), "Unexpected trailing observations"
    results.update({"fit_records": FIT_COUNT, "rectangles": shapes, "byte_exact": True})
    (options.output / "results.json").write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
