#!/usr/bin/env python3

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import time


WAIT_SECONDS = 10
STOP_SECONDS = 5
POLL_SECONDS = 0.02
SETTLE_SECONDS = 0.25
DISPLAY_SCALES = (1, 1.25, 2, 1)


@contextmanager
def running_process(command, environment, log):
    with log.open("w") as output:
        process = subprocess.Popen(command, env=environment, stdout=output, stderr=subprocess.STDOUT)
        try:
            yield process
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=STOP_SECONDS)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=STOP_SECONDS)


def wait_for(read, accepts, processes, stable_seconds=0):
    deadline = time.monotonic() + WAIT_SECONDS
    latest = None
    stable_value = None
    stable_since = None
    while time.monotonic() < deadline:
        for process in processes:
            if process.poll() is not None:
                raise RuntimeError(f"Process {process.pid} exited with {process.returncode}")

        try:
            latest = read()
        except (OSError, ValueError):
            pass
        else:
            if accepts(latest):
                now = time.monotonic()
                if latest != stable_value:
                    stable_value = latest
                    stable_since = now

                if now - stable_since >= stable_seconds:
                    return latest
            else:
                stable_value = None
                stable_since = None

        time.sleep(POLL_SECONDS)

    raise TimeoutError(f"Display transition did not settle; latest value: {latest}")


def sway_request(socket, *arguments):
    command = ["swaymsg", "-s", socket, *map(str, arguments)]
    result = subprocess.run(command, text=True, capture_output=True, check=True)
    value = json.loads(result.stdout)
    if arguments[0] != "-t" and not all(item.get("success") for item in value):
        raise RuntimeError(f"Compositor rejected {arguments}: {value}")

    return value


def select_output(socket, requested):
    outputs = sway_request(socket, "-t", "get_outputs", "-r")
    candidates = [output for output in outputs if output["active"] and (not requested or output["name"] == requested)]
    if len(candidates) != 1:
        raise ValueError("Select one active compositor output with --output")

    return candidates[0]


def physical_cell(record):
    columns, rows = record["columns"], record["rows"]
    width, height = record["pixel_width"], record["pixel_height"]
    if columns <= 0 or rows <= 0 or width <= 0 or height <= 0 or width % columns or height % rows:
        raise ValueError(f"Invalid physical PTY dimensions: {record}")

    return width // columns, height // rows


def exercise_scales(options, socket, output):
    environment = os.environ.copy()
    environment.pop("QT_QUICK_BACKEND", None)
    environment.pop("QT_SCALE_FACTOR", None)
    environment.pop("QT_SCREEN_SCALE_FACTORS", None)
    environment.pop("QT_DEVICE_PIXEL_RATIO", None)
    environment.pop("QT_ENABLE_HIGHDPI_SCALING", None)
    environment.update(QT_QPA_PLATFORM="wayland", QSG_RHI_BACKEND="opengl", LIBGL_ALWAYS_SOFTWARE="1", QSG_RENDER_LOOP="threaded")
    results = []

    def record_transition(scale, record):
        results.append(dict(scale=scale, cell=physical_cell(record), pty=record))
        (options.artifacts / "transitions.json").write_text(json.dumps(results, indent=2) + "\n")

    service = Path(__file__).resolve().parent.parent
    fixture = service.parent.parent / "tools/gui_window_size.py"
    with TemporaryDirectory(prefix="telar-scale-") as temporary:
        directory = Path(temporary)
        endpoint = directory / "runtime.sock"
        record_path = directory / "window.json"
        environment.update(TELAR_HISTORY=str(directory / "history.db"), XDG_DATA_HOME=str(directory / "data"))
        runtime_command = [str(options.runtime), "server", "--no-config", "--fresh", "--socket", str(endpoint)]
        with running_process(runtime_command, environment, options.artifacts / "runtime.log") as runtime:
            wait_for(endpoint.exists, bool, (runtime,))
            sway_request(socket, "output", output["name"], "scale", DISPLAY_SCALES[0])
            command = [str(options.gui), "--no-config", "--fresh", "--socket", str(endpoint),
                       "--cwd", str(directory), sys.executable, str(fixture), str(record_path)]
            with running_process(command, environment, options.artifacts / "gui.log") as gui:
                processes = runtime, gui
                read_record = lambda: json.loads(record_path.read_text())
                previous = wait_for(read_record, lambda value: physical_cell(value), processes, SETTLE_SECONDS)
                record_transition(DISPLAY_SCALES[0], previous)
                for scale in DISPLAY_SCALES[1:]:
                    old_cell = physical_cell(previous)
                    sway_request(socket, "output", output["name"], "scale", scale)
                    current = wait_for(read_record, lambda value: value["revision"] > previous["revision"] and physical_cell(value) != old_cell, processes, SETTLE_SECONDS)
                    cell = physical_cell(current)
                    if scale > results[-1]["scale"]:
                        if cell[0] <= old_cell[0] or cell[1] <= old_cell[1]:
                            raise AssertionError(f"Increasing density did not increase physical cells: {old_cell} -> {cell}")
                    elif cell != tuple(results[0]["cell"]):
                        raise AssertionError(f"Returning to the initial density changed physical cells: {cell}")

                    record_transition(scale, current)
                    previous = current

    return results


def main():
    parser = argparse.ArgumentParser(description="Check live Sway density changes against an isolated GUI's actual PTY winsize")
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--gui", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--output")
    parser.add_argument("--sway-socket", default=os.environ.get("SWAYSOCK"))
    options = parser.parse_args()
    options.runtime = options.runtime.resolve(strict=True)
    options.gui = options.gui.resolve(strict=True)
    options.artifacts = options.artifacts.resolve()
    options.artifacts.mkdir(mode=0o700, parents=True, exist_ok=False)
    if not options.sway_socket:
        parser.error("Set SWAYSOCK or --sway-socket")

    output = select_output(options.sway_socket, options.output)
    report = dict(output=output["name"], initial_scale=output["scale"], status="failed")
    try:
        report["transitions"] = exercise_scales(options, options.sway_socket, output)
        report["status"] = "passed"
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        try:
            sway_request(options.sway_socket, "output", output["name"], "scale", output["scale"])
        except Exception as error:
            report["status"] = "failed"
            report["restore_error"] = str(error)
            raise
        finally:
            progress = options.artifacts / "transitions.json"
            if progress.exists():
                report["transitions"] = json.loads(progress.read_text())

            (options.artifacts / "result.json").write_text(json.dumps(report, indent=2) + "\n")

    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
