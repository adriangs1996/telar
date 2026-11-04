"""Build private typing/tab-switch probes with measured-interval thread CPU snapshots."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from build_tab_switch_probe import build as build_switch_probe


def copy_typing_probe(directory, source):
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    for name in ("echo_latency.py", "headless_client.py", "perf_e2e.py", "load_latency.py",
                 "gui_tui_latency.py", "gui_tui_latency.m", "gui_view.h", "gui_tui_marker.py",
                 "terminal_bench_fixture.py", "terminal_bench_report.py", "bench_stack.py",
                 "benchmark_host.py", "image_bench_fixture.py", "image_patterns.py", "kitty_stream.py"):
        shutil.copy2(source / name, directory / name)
    (directory / "base-build.json").write_text(json.dumps(dict(
        scope="Unmodified ordinary typing probe sources before thread-counter hooks.",
        sha256={file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in directory.iterdir() if file.is_file()},
    ), indent=2) + "\n")


def build(output, workload="tabs", sampling="periodic"):
    if workload not in ("tabs", "typing") or sampling not in ("periodic", "boundaries"):
        raise ValueError("Unsupported thread CPU workload or sampling mode")
    directory = Path(output).resolve()
    source = Path(__file__).resolve().parent
    if workload == "tabs":
        build_switch_probe(directory)
        (directory / "build.json").rename(directory / "base-build.json")
    else:
        copy_typing_probe(directory, source)
    for name in ("macos_thread_cpu.h", "macos_thread_cpu.c", "thread_cpu_report.py"):
        shutil.copy2(source / name, directory / name)
    path = directory / "gui_tui_latency.m"
    contents = '#include "macos_thread_cpu.h"\nstatic int thread_cpu_active;\n' + path.read_text()
    capture_path = '[[display_directory stringByAppendingPathComponent:@"thread-cpu.jsonl"] fileSystemRepresentation]'
    begin = f"telar_thread_cpu_begin({capture_path})" if sampling == "periodic" else f"telar_thread_cpu_begin_sampling({capture_path}, telar_thread_cpu_boundaries)"
    hooks = {
        "        getrusage(RUSAGE_SELF, &measurement_start_usage);":
            f'        if ({begin} != 0) _exit(75);\n'
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
        scope="Diagnostic only; no acceptance timings. Two hooks bracket measured actions; periodic mode adds a private100ms observer, boundaries mode creates no observer thread.",
        workload=workload, sampling=sampling,
        commands=commands,
        sha256={file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in directory.iterdir() if file.is_file()},
    ), indent=2) + "\n")
    return directory / "probe.dylib"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--workload", choices=("tabs", "typing"), default="tabs")
    parser.add_argument("--sampling", choices=("periodic", "boundaries"), default="periodic")
    options = parser.parse_args()
    print(build(options.output, options.workload, options.sampling))
