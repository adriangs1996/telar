#!/usr/bin/env python3

import argparse
from pathlib import Path
import runpy


def main():
    parser = argparse.ArgumentParser(description="Exercise the telar CLI starting, bridging, persisting and stopping the runtime")
    parser.add_argument("--telar", type=Path, required=True)
    parser.add_argument("--checkpoint-probe", type=Path, required=True)
    arguments = parser.parse_args()
    checks = runpy.run_path(str(Path(__file__).resolve().parents[1] / "tools/check_server_cli.py"))
    checks["check_runtime"](arguments.telar.resolve(), arguments.checkpoint_probe.resolve())
    checks["check_unwritable_shell_integration"](arguments.telar.resolve(), arguments.checkpoint_probe.resolve())


if __name__ == "__main__":
    main()
