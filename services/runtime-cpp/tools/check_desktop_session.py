#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time


def fingerprint(path):
    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def build_probe(root, artifacts, compiler, render):
    desktop = root.parent / "desktop-mode"
    sources = [root / ("tests/desktop_render_probe.cpp" if render else "tests/desktop_session_probe.cpp"), desktop / "ui/workbench/runtime_connection.cpp",
               desktop / "ui/workbench/terminal_screen.cpp", desktop / "login_shell.cpp"]
    if render:
        sources.extend(desktop / "ui/workbench" / name for name in ("terminal_item.cpp", "terminal_input.cpp"))
    dependencies = [*sources, root / "tests/protocol_peer.hpp", root / "tests/desktop_test_support.hpp", *desktop.joinpath("telar_client").rglob("*.hpp"),
                    desktop / "ui/workbench/runtime_connection.hpp", desktop / "ui/workbench/terminal_screen.hpp",
                    desktop / "login_shell.hpp", desktop / "log_categories.hpp", desktop / "trace.hpp",
                    desktop / "ui/workbench/terminal_item.hpp", desktop / "ui/workbench/terminal_input.hpp"]
    artifacts.mkdir(parents=True, exist_ok=False)
    modules = ["Qt6Core", "Qt6Network"] + (["Qt6Gui", "Qt6Quick"] if render else [])
    qt_flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", *modules], text=True))
    probe = artifacts / "desktop-session-probe"
    command = [compiler, "-std=c++23", "-O2", "-DTELAR_DEBUG=0", "-DQT_NO_DEBUG_OUTPUT",
               "-I", str(desktop), *map(str, sources), *qt_flags, "-o", str(probe)]
    subprocess.run(command, check=True)
    manifest = {"command": command, "sources": [fingerprint(source) for source in sorted(set(dependencies))],
                "probe": fingerprint(probe)}
    (artifacts / "sources.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return probe


def check(binary, probe, shell, images, native):
    with tempfile.TemporaryDirectory(prefix="telar-desktop-session-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        environment = {key: value for key, value in os.environ.items() if not key.startswith(("TELAR_", "DYLD_"))}
        for name in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"):
            directory = root / name.lower()
            directory.mkdir(mode=0o700)
            environment[name] = str(directory)
        environment.update(SHELL=shell, TERM="xterm-256color", TMPDIR=str(root), PATH="/usr/bin:/bin:/usr/sbin:/sbin",
                           LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8", PS1="probe> ", ZDOTDIR=environment["HOME"])
        if images:
            environment["QT_QPA_PLATFORM"] = "cocoa" if native else "offscreen"
        socket = root / "runtime.sock"
        configuration = root / "runtime.lua"
        configuration.write_text('return {api_version=2,runtime={history={path=' + json.dumps(str(root / "history.db")) + '},proxy={enabled=false},session={persist=false}}}\n')
        output = root / "session.json"
        with (root / "server.log").open("w+") as log:
            server = subprocess.Popen([str(binary), "server", "--socket", str(socket), "--config", str(configuration)],
                                      env=environment, stdout=log, stderr=log)
            result = {}
            try:
                deadline = time.monotonic() + 20
                while not socket.exists():
                    if server.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Runtime did not start")
                    time.sleep(0.01)
                command = [str(probe), str(socket), str(output)] + (["native"] if native else [])
                completed = subprocess.run(command, env=environment,
                                           capture_output=True, text=True, timeout=120)
                if completed.returncode:
                    raise RuntimeError(f"Desktop session probe exited {completed.returncode}: {completed.stderr}")
                result = {"passed": True, "snapshots": json.loads(output.read_text()), "probe_stderr": completed.stderr}
                if images:
                    images.mkdir(parents=True, exist_ok=True)
                    for image in root.glob("session.json*.png*"):
                        shutil.copy2(image, images / image.name)
            except Exception as error:
                result = {"passed": False, "error": str(error)}
            finally:
                if server.poll() is None:
                    server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
                log.flush()
                log.seek(0)
                diagnostics = log.read()
                if not result.get("passed"):
                    result["runtime_log"] = diagnostics
                if server.returncode not in (0, -15) or "ERROR: AddressSanitizer" in diagnostics or "runtime error:" in diagnostics:
                    result.update(passed=False, runtime_log=diagnostics, shutdown_code=server.returncode)
            return result


def compare_native(implementations, images, shell):
    states = {language: result["snapshots"].copy() for language, result in implementations.items()}
    comparisons = {}
    for field, filename in (("render", "session.json.png.rgba"), ("resized_render", "session.json.resized.png.rgba")):
        metadata = {language: state.pop(field) for language, state in states.items()}
        pixels = {language: (images / language / Path(shell).name / filename).read_bytes() for language in states}
        expected = metadata["zig"]["width"] * metadata["zig"]["height"] * 4
        dimensions_match = all(metadata["zig"][key] == metadata["cpp"][key] for key in ("width", "height"))
        if not dimensions_match or len(pixels["zig"]) != expected or len(pixels["cpp"]) != expected:
            comparisons[field] = {"passed": False, "reason": "Pixel dimensions or readback lengths differ"}
            continue

        changed_channels = 0
        maximum_rgb_delta = 0
        alpha_matches = True
        for index, (left, right) in enumerate(zip(pixels["zig"], pixels["cpp"])):
            if left == right:
                continue
            changed_channels += 1
            if index % 4 == 3:
                alpha_matches = False
            else:
                maximum_rgb_delta = max(maximum_rgb_delta, abs(left - right))
        comparisons[field] = {"passed": alpha_matches and maximum_rgb_delta <= 1,
                              "changed_channels": changed_channels, "maximum_rgb_delta": maximum_rgb_delta,
                              "alpha_matches": alpha_matches, "total_channels": expected}
    exact_state = states["zig"] == states["cpp"]
    return {"passed": exact_state and all(result["passed"] for result in comparisons.values()),
            "terminal_state_exact": exact_state, "pixel_readbacks": comparisons}


def main():
    parser = argparse.ArgumentParser(description="Exercise actual Desktop Qt connection and screen code against both runtimes")
    for name in ("zig", "cpp", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--probe", type=Path)
    parser.add_argument("--compiler", default="/opt/homebrew/opt/llvm/bin/clang++")
    parser.add_argument("--shells", nargs="+", default=["/bin/sh", "/bin/bash", "/bin/zsh"])
    parser.add_argument("--render", action="store_true")
    parser.add_argument("--native", action="store_true")
    arguments = parser.parse_args()
    if arguments.native and not arguments.render:
        parser.error("--native requires --render")
    root = Path(__file__).resolve().parent.parent
    if arguments.probe:
        probe = arguments.probe.resolve()
    else:
        if not arguments.artifacts:
            parser.error("Pass --artifacts to build or --probe to reuse a frozen probe")
        probe = build_probe(root, arguments.artifacts.resolve(), arguments.compiler, arguments.render)
    binaries = {"zig": arguments.zig.resolve(), "cpp": arguments.cpp.resolve(), "probe": probe}
    scope = "Actual Desktop RuntimeConnection, TerminalScreen and login_shell with QCoreApplication; no native windows or GPU rendering."
    if arguments.render:
        scope = "Actual Desktop TerminalItem, IME, keyboard, resize and Qt Quick software rendering through the offscreen platform; no native Spaces or GPU validation."
    if arguments.native:
        scope = "Actual Desktop TerminalItem, IME, keyboard and resize in a native macOS Cocoa window with a verified Metal device. Terminal state and alpha are exact; RGB readback tolerance is one level per channel, based on same-runtime controls. No Spaces switching."
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "acceptance": "functional_only",
              "scope": scope,
              "binaries": {name: fingerprint(path) for name, path in binaries.items()}, "cases": []}
    for shell in arguments.shells:
        case = {"shell": shell, "implementations": {}}
        for language in ("zig", "cpp"):
            images = arguments.output.with_suffix("") / language / Path(shell).name if arguments.render else None
            result = check(binaries[language], probe, shell, images, arguments.native)
            case["implementations"][language] = result
            print(language, shell, "passed" if result["passed"] else result.get("error", "failed"), flush=True)
        implementations = case["implementations"]
        case["equivalent"] = all(result["passed"] for result in implementations.values()) and implementations["zig"]["snapshots"] == implementations["cpp"]["snapshots"]
        if arguments.native and all(result["passed"] for result in implementations.values()):
            case["comparison"] = compare_native(implementations, arguments.output.with_suffix(""), shell)
            case["equivalent"] = case["comparison"]["passed"]
        report["cases"].append(case)
    report["passed"] = all(case["equivalent"] for case in report["cases"])
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
