#!/usr/bin/env python3
"""Compare each CLI with its own runtime. Never cross the wire schemas."""

import argparse
import importlib.util
import hashlib
import json
from pathlib import Path
import re
import tempfile

spec = importlib.util.spec_from_file_location("exec_runtime_test", Path(__file__).resolve().parents[1] / "tests/exec_runtime_test.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


def normalized(data, fixture):
    data = data.replace(str(fixture.root).encode(), b"@ROOT")
    data = re.sub(rb"setup execution \d+", b"setup execution @ID", data)
    data = re.sub(rb'"execution_id":\d{6,}', b'"execution_id":"@ID"', data)
    data = re.sub(rb'"workspace_id":\d+', b'"workspace_id":"@ID"', data)
    data = re.sub(rb'"revision":\d+', b'"revision":"@REVISION"', data)
    data = re.sub(rb'"last_ms":\d+', b'"last_ms":"@TIME"', data)
    data = re.sub(rb'last \d\d:\d\d:\d\d UTC', b'last @TIME UTC', data)
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    arguments.scratch.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix="er-", dir=arguments.scratch) as directory:
        root = Path(directory)
        zig = checks.run_suite(arguments.zig, root / "z")
        cpp = checks.run_suite(arguments.cpp, root / "c")
        report = {"matches": [], "differences": {}, "runtime_gaps": {}, "dynamic_observations": [], "intentional_wire_differences": {}}
        dynamic = {"runtime/metrics-json", "runtime/metrics-text", "runtime/watch"}
        wire = {"api/json", "api/text", "runtime/status-json", "runtime/status-text", "fixture/status-port"}
        for name, expected in zig.results.items():
            actual = cpp.results[name]
            if name in dynamic:
                report["dynamic_observations"].append(name)
                continue
            if name in wire:
                assert expected[0] == actual[0] and expected[2] == actual[2]
                if name == "api/json":
                    zig_contract = json.loads(expected[1])
                    cpp_contract = json.loads(actual[1])
                    for section in ("client_requests", "server_messages", "agent_statuses", "bounds"):
                        for key, value in zig_contract[section].items():
                            assert cpp_contract[section][key] == value
                elif name.endswith("-json"):
                    left_status = json.loads(expected[1])
                    right_status = json.loads(actual[1])
                    left_status.pop("schema_version")
                    right_status.pop("schema_version")
                    assert left_status == right_status
                elif name != "api/text":
                    left_text = re.sub(rb"Schema: [^\n]+", b"Schema: @NATIVE", expected[1])
                    right_text = re.sub(rb"Schema: [^\n]+", b"Schema: @NATIVE", actual[1])
                    assert left_text == right_text
                report["intentional_wire_differences"][name] = {"zig": expected[1].decode(), "cpp": actual[1].decode()}
                continue
            left = (expected[0], *(normalized(item, zig) for item in expected[1:]))
            right = (actual[0], *(normalized(item, cpp) for item in actual[1:]))
            if left == right:
                report["matches"].append(name)
            else:
                def describe(item):
                    return repr(item) if len(item) <= 2048 else {"bytes": len(item), "sha256": hashlib.sha256(item).hexdigest()}
                difference = {"zig": [left[0], *(describe(item) for item in left[1:])], "cpp": [right[0], *(describe(item) for item in right[1:])]}
                if name in {"exec/detach", "exec/retained-start"}:
                    assert left[0] == right[0] and left[2] == right[2]
                    assert left[1].replace(b'"starting"', b'"running"') == right[1]
                    report["runtime_gaps"][name] = difference
                elif name.startswith("limits/"):
                    # The C++ runtime does not report executions.retained_bytes.
                    # All other rows must still agree, including client reports.
                    if name != "limits/text":
                        expected_limits = json.loads(left[1])
                        actual_limits = json.loads(right[1])
                        expected_limits["limits"] = [entry for entry in expected_limits["limits"] if entry["name"] != "executions.retained_bytes"]
                        assert expected_limits == actual_limits, difference
                    report["runtime_gaps"][name] = difference
                elif name == "history/batch-stats":
                    assert left[0] == right[0] and left[2] == right[2]
                    assert sorted(left[1].splitlines()) == sorted(right[1].splitlines())
                    report["runtime_gaps"][name] = difference
                else:
                    report["differences"][name] = difference
        arguments.output.write_text(json.dumps(report, indent=2) + "\n")
        print(f"{len(report['matches'])} exact cases; {len(report['differences'])} unexpected differences; {len(report['runtime_gaps'])} runtime gaps; {len(dynamic)} live observations; {len(wire)} intentional wire outputs")
        for name in report["differences"]:
            print("DIFF", name)
        raise SystemExit(bool(report["differences"]))


if __name__ == "__main__":
    main()
