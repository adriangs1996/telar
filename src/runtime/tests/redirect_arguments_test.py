#!/usr/bin/env python3

import argparse
from pathlib import Path
import runpy


def main():
    parser = argparse.ArgumentParser(description="Check the arguments the root-run traffic redirect refuses")
    parser.add_argument("--runtime", type=Path, required=True)
    arguments = parser.parse_args()
    checks = runpy.run_path(str(Path(__file__).resolve().parents[1] / "tools/check_redirect_arguments.py"))
    checks["check_arguments"](arguments.runtime.resolve())


if __name__ == "__main__":
    main()
