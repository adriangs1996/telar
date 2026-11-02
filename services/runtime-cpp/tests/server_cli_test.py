#!/usr/bin/env python3

import argparse
from pathlib import Path
import runpy


def main():
    parser = argparse.ArgumentParser(description="Exercise native runtime startup, bridge, persistence and shutdown")
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--checkpoint-probe", type=Path, required=True)
    arguments = parser.parse_args()
    checks = runpy.run_path(str(Path(__file__).resolve().parents[1] / "tools/check_server_cli.py"))
    result = checks["check_runtime"](arguments.runtime.resolve(), arguments.checkpoint_probe.resolve())
    for name, passed in result.items():
        if not passed:
            raise RuntimeError(f"Runtime check failed: {name}")
        print(f"{name}: passed")


if __name__ == "__main__":
    main()
