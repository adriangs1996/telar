import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


repository = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(repository / "tools"))
import gui_tui_latency


def interpreter_image():
    if sys.platform != "darwin":
        return Path(sys.executable).resolve()

    process_library = ctypes.CDLL(ctypes.util.find_library("proc"))
    process_library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    process_library.proc_pidpath.restype = ctypes.c_int
    process_path_capacity = 4096
    buffer = ctypes.create_string_buffer(process_path_capacity)
    if process_library.proc_pidpath(os.getpid(), buffer, len(buffer)) <= 0:
        raise RuntimeError("Cannot resolve the running Python process image")

    return Path(os.fsdecode(buffer.value))


def main():
    parser = argparse.ArgumentParser(description="Capture both Telar GUIs with a synthetic workload identified as a built-in agent")
    parser.add_argument("provider", choices=("claude", "codex", "pi", "cursor-agent", "opencode"))
    parser.add_argument("zig_binary", type=Path)
    parser.add_argument("output_directory", type=Path)
    options, arguments = parser.parse_known_args()
    output = options.output_directory.resolve()
    if output.exists():
        parser.error("The output directory must be new")
    records = []
    interpreter = None
    original_command = gui_tui_latency.client_command

    def client_command(mode, binary, cpp_gui, config, fixture):
        nonlocal interpreter
        source = Path(fixture[1])
        if source.name not in ("terminal_bench_fixture.py", "gui_tui_marker.py"):
            raise ValueError(f"Unexpected terminal fixture: {source}")
        if interpreter is None:
            directory = output / "fixtures" / "interpreter"
            directory.mkdir(parents=True, exist_ok=True)
            interpreter = directory / options.provider
            shutil.copy2(interpreter_image(), interpreter)
            if sys.platform == "darwin":
                subprocess.run(["codesign", "--force", "--sign", "-", str(interpreter)], check=True)
        records.append({"mode": mode, "source": str(source), "sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "interpreter": str(interpreter), "interpreter_sha256": hashlib.sha256(interpreter.read_bytes()).hexdigest()})
        return original_command(mode, binary, cpp_gui, config, [str(interpreter), *fixture[1:]])

    original_arguments = sys.argv
    gui_tui_latency.client_command = client_command
    sys.argv = [str(repository / "tools/gui_tui_latency.py"), str(options.zig_binary), str(output), *arguments, "--mode", "telar"]
    try:
        gui_tui_latency.main()
    finally:
        gui_tui_latency.client_command = original_command
        sys.argv = original_arguments
        if records:
            (output / "provider-fixtures.json").write_text(json.dumps({"provider": options.provider, "synthetic_workload": True, "fixtures": records}, indent=2) + "\n")


if __name__ == "__main__":
    main()
