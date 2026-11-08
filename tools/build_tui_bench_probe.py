"""Build an isolated ASCII TUI harness with the unchanged native presentation probe.

Run OUT/gui_tui_latency.py with --cases tui, --mode gui-cpp, and the
ordinary explicit GUI/runtime/config arguments. Final runtime text is verified
after GUI exit, before owned-runtime cleanup. Native120 remains unverified.
The optional coalesced write mode is a labeled producer-boundary diagnostic;
the ordinary timing report rejects it.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from build_thread_cpu_probe import copy_typing_probe


def build(output, write_mode="split"):
    if write_mode not in ("split", "coalesced"):
        raise ValueError("Unknown TUI write mode")
    source = Path(__file__).resolve().parent
    root = source.parent
    directory = Path(output).resolve()
    copy_typing_probe(directory, source)
    for name in ("tui_bench_fixture.py", "tui_coalesced_fixture.py", "tui_bench_trace.py", "tui_bench_report.py", "read_cpp_pane.cpp"):
        shutil.copy2(source / name, directory / name)
    path = directory / "gui_tui_latency.py"
    text = path.read_text()

    def replace(before, after, count=1):
        nonlocal text
        if text.count(before) != count:
            raise ValueError(f"TUI harness anchor changed: {before!r}")
        text = text.replace(before, after)

    replace("def measure(mode, directory, setup):", "from tui_bench_report import finish as finish_tui\n\ndef measure(mode, directory, setup):")
    replace("    runtime = runtime_program(mode, getattr(options, 'cpp_runtime', None))",
            "    if mode != 'gui-cpp' or getattr(options, 'case', None) != 'tui':\n        raise ValueError('This harness requires --cases tui and a complete Telar stack')\n    runtime = runtime_program(mode, getattr(options, 'cpp_runtime', None))")
    fixture = "tui_coalesced_fixture.py" if write_mode == "coalesced" else "tui_bench_fixture.py"
    replace("with_name('terminal_bench_fixture.py')", f"with_name('{fixture}')")
    replace("case == 'single'", "case in ('single', 'tui')", count=2)
    replace("TELAR_DISPLAY_LAYOUT=case.removesuffix('-load')", "TELAR_DISPLAY_LAYOUT='single' if case == 'tui' else case.removesuffix('-load')")
    replace("choices=['single', 'splits', 'tabs', 'splits-load', 'tabs-load']", "choices=['tui']")
    replace("default=['single'])", "default=['tui'])")
    replace("'terminal_bench_report.py', 'bench_stack.py', 'benchmark_host.py')}",
            "'terminal_bench_report.py', 'bench_stack.py', 'benchmark_host.py', 'tui_bench_fixture.py', 'tui_coalesced_fixture.py', 'tui_bench_trace.py', 'tui_bench_report.py', 'read_cpp_pane.cpp', 'read-cpp-pane')}")
    replace("            try:\n                if getattr(options, 'image_size', None) and identity is not None:",
            "            try:\n                if identity is not None:\n                    finish_tui(directory, mode, Path(__file__).with_name('read-cpp-pane'), options.samples + WARMUP)\n                if getattr(options, 'image_size', None) and identity is not None:")
    path.write_text(text)
    commands = [
        ["clang++", "-O2", "-std=c++23", "-Wall", "-Wextra", "-Werror",
         "-I", str(root / "src/runtime-cpp/tests"),
         "-I", str(root / "lib/telar-client/include"), "-I", str(root / "lib/telar-base/include"),
         str(directory / "read_cpp_pane.cpp"), "-o", str(directory / "read-cpp-pane")],
        ["clang", "-dynamiclib", "-O2", "-fobjc-arc", "-framework", "AppKit",
         "-framework", "QuartzCore", "-framework", "Metal",
         str(directory / "gui_tui_latency.m"), "-o", str(directory / "probe.dylib")],
    ]
    with (directory / "build.log").open("w") as log:
        for command in commands:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    shutil.copy2(__file__, directory / Path(__file__).name)
    (directory / "build.json").write_text(json.dumps(dict(
        scope=__doc__, write_mode=write_mode, commands=commands,
        sha256={file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in directory.iterdir() if file.is_file()},
    ), indent=2) + "\n")
    return directory / "gui_tui_latency.py"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--write-mode", choices=("split", "coalesced"), default="split")
    args = parser.parse_args()
    print(build(args.output, args.write_mode))
