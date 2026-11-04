"""Build a private tab-switch probe with measured-interval thread CPU snapshots."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from build_tab_switch_probe import build as build_switch_probe


def build(output):
    directory = Path(output).resolve()
    build_switch_probe(directory)
    source = Path(__file__).resolve().parent
    (directory / "build.json").rename(directory / "base-build.json")
    for name in ("macos_thread_cpu.h", "macos_thread_cpu.c", "thread_cpu_report.py"):
        shutil.copy2(source / name, directory / name)
    path = directory / "gui_tui_latency.m"
    contents = '#include "macos_thread_cpu.h"\nstatic int thread_cpu_active;\n' + path.read_text()
    hooks = {
        "        getrusage(RUSAGE_SELF, &measurement_start_usage);":
            '        if (telar_thread_cpu_begin([[display_directory stringByAppendingPathComponent:@"thread-cpu.jsonl"] fileSystemRepresentation]) != 0) _exit(75);\n'
            '        thread_cpu_active = 1;\n'
            '        getrusage(RUSAGE_SELF, &measurement_start_usage);',
        "    finished=YES;":
            '    if (thread_cpu_active) {\n'
            '        thread_cpu_active = 0;\n'
            '        if (telar_thread_cpu_end() != 0) _exit(75);\n'
            '    }\n'
            '    finished=YES;',
    }
    for anchor, replacement in hooks.items():
        if contents.count(anchor) != 1:
            raise ValueError(f"thread CPU hook changed: {anchor}")
        contents = contents.replace(anchor, replacement)
    path.write_text(contents)
    commands = [
        ["clang", "-O2", "-Wall", "-Wextra", "-Werror", "-c", str(directory / "macos_thread_cpu.c"), "-o", str(directory / "thread-cpu.o")],
        ["clang", "-dynamiclib", "-O2", "-fobjc-arc", "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Metal",
         str(path), str(directory / "thread-cpu.o"), "-o", str(directory / "probe.dylib")],
    ]
    with (directory / "thread-cpu-build.log").open("w") as log:
        for command in commands:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    shutil.copy2(__file__, directory / Path(__file__).name)
    (directory / "build.json").write_text(json.dumps(dict(
        scope="Diagnostic only; no acceptance timings. Two hooks bracket measured actions and a private100ms thread observer.",
        commands=commands,
        sha256={file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in directory.iterdir() if file.is_file()},
    ), indent=2) + "\n")
    return directory / "probe.dylib"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    print(build(parser.parse_args().output))
