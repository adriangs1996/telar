#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import struct
import tempfile

from check_clone_parity import run_runtime


def text16(value):
    return struct.pack("<H", len(value)) + value


def checkpoint(version, first_pane):
    output = bytearray(b"TELARCKP" + struct.pack("<HQQQQ", version, 2, 3, first_pane + 3, 100))
    output += b"\x01" + struct.pack("<Q", 1) + text16(b"/tmp") + text16(b"Persistent workspace")
    output += struct.pack("<Q", 1) + text16(b"Shells")
    output += b"\x02" + struct.pack("<QQ", 1, 2) + text16(b"Persistent tab")
    for offset in range(3):
        output += b"\x03" + struct.pack("<QQQ", first_pane + offset, 1, 2 if offset == 2 else 1)
        output += text16(b"/tmp") + struct.pack("<HHH", 80, 24, 1)
        arguments = b"/bin/cat\0"
        output += struct.pack("<I" if version >= 9 else "<H", len(arguments)) + arguments
        output += b"\0" + text16(b"")
        if version >= 2:
            output += text16(b"") + b"\0"
        if version >= 8 or version == 4:
            output += b"\0"
    output += b"\0"
    return output


def main():
    parser = argparse.ArgumentParser(description="Restore checkpoints 1–10 and exercise large pane identities")
    for name in ("zig", "cpp", "probe", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    arguments = parser.parse_args()
    binaries = {name: getattr(arguments, name).resolve() for name in ("zig", "cpp", "probe")}
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "binaries": {
        name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        for name, path in binaries.items()}, "cases": []}
    cases = [(version, 1) for version in range(1, 11)] + [(10, 2**63 + 1), (10, 2**64 - 5)]
    try:
        for version, first_pane in cases:
            case = {"version": version, "first_pane": first_pane, "implementations": []}
            report["cases"].append(case)
            for implementation in ("zig", "cpp"):
                with tempfile.TemporaryDirectory(prefix="telar-legacy-checkpoint-", dir="/tmp") as temporary:
                    root = Path(temporary)
                    destination = root / "session.ckpt"
                    destination.write_bytes(checkpoint(version, first_pane))
                    destination.chmod(0o600)
                    (root / "expected").write_text(f"1 1 2 {first_pane} {first_pane + 1} {first_pane + 2} 1 2 3\n")
                    run_runtime(binaries[implementation], binaries["probe"], root, [], "verify-basic")
                    assert destination.read_bytes()[:10] == b"TELARCKP\x0a\0"
                    run_runtime(binaries[implementation], binaries["probe"], root, [], "verify-basic")
                    case["implementations"].append(implementation)
            print(f"version={version} first_pane={first_pane}: both implementations passed", flush=True)
    except Exception as error:
        report["failure"] = str(error)
        raise
    finally:
        arguments.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
