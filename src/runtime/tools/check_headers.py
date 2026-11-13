#!/usr/bin/env python3
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
from pathlib import Path
import shlex
import subprocess


def compiler_arguments(entry):
    arguments = entry.get("arguments") or shlex.split(entry["command"])
    retained = []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in ("-c", "-o"):
            index += 2
            continue
        retained.append(argument)
        index += 1
    return retained


def main():
    parser = argparse.ArgumentParser(description="Compile each runtime header without inherited includes")
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=3)
    parser.add_argument("--headers", nargs="+", help="Check only these paths relative to the runtime source directory")
    arguments = parser.parse_args()
    if arguments.jobs < 1:
        parser.error("--jobs must be positive")
    source = Path(__file__).resolve().parents[1]
    entries = json.loads((arguments.build_dir / "compile_commands.json").read_text())
    entry = next(item for item in entries if Path(item["file"]).resolve() == source / "main.cpp")
    command = compiler_arguments(entry)
    headers = sorted(path for path in source.rglob("*.hpp") if not any(part.startswith("out") for part in path.relative_to(source).parts[:-1]))
    if arguments.headers:
        selected = {source / name for name in arguments.headers}
        if not selected.issubset(headers):
            parser.error("A requested header is not part of the runtime")
        headers = [path for path in headers if path in selected]

    def check(header):
        result = subprocess.run([*command, "-fsyntax-only", "-x", "c++", "-include", str(header), "/dev/null"],
                                cwd=entry["directory"], capture_output=True, text=True)
        return {"header": str(header.relative_to(source)), "passed": result.returncode == 0, "diagnostics": result.stderr}

    with ThreadPoolExecutor(max_workers=arguments.jobs) as executor:
        results = list(executor.map(check, headers))
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "command": command,
              "passed": all(result["passed"] for result in results), "headers": results}
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    for result in results:
        if not result["passed"]:
            print(f"{result['header']}:\n{result['diagnostics']}", flush=True)
    print(f"{sum(result['passed'] for result in results)}/{len(results)} standalone headers passed")
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
