"""Final runtime-screen oracle; does not verify every presented TUI frame."""

import hashlib
import json
from pathlib import Path
import subprocess

from tui_bench_trace import FULL_INTERVAL, WORKLOAD, changed_rows, row_text


def validate_screen(trace, actual, sequence):
    write_mode = trace.get("write_mode", "split")
    if write_mode not in ("split", "coalesced"):
        raise ValueError("Unknown TUI write mode")
    for key in ("sequence", "columns", "rows", "pid", "pane_id", "pane_generation", "body_bytes"):
        if type(trace.get(key)) is not int or trace[key] <= 0:
            raise ValueError("Invalid TUI identity, dimensions or counters")
    if trace.get("workload") != WORKLOAD or trace["sequence"] != sequence or sequence < FULL_INTERVAL:
        raise ValueError("Wrong TUI workload or final sequence")
    columns, rows = trace["columns"], trace["rows"]
    if columns > 2000 or rows > 2000 or columns * rows > 262144:
        raise ValueError("TUI screen exceeds read oracle bounds")
    last_full = sequence - sequence % FULL_INTERVAL
    epochs = [last_full] * rows
    for update in range(last_full + 1, sequence + 1):
        for row in changed_rows(rows, update):
            epochs[row] = update
    if trace.get("row_epochs") != epochs or any(type(value) is not int for value in trace["row_epochs"]):
        raise ValueError("Missing or stale TUI row updates")
    if trace.get("capture_cell") is not False:
        raise ValueError("Capture witness survived the measured full repaint")
    expected = [list(row_text(columns, row, epoch)) for row, epoch in enumerate(epochs)]
    expected[min(7, rows - 1)][min(19, columns - 1)] = " "
    text = "\n".join("".join(row) for row in expected)
    if trace.get("expected_text") != text or actual not in (text, text + "\n"):
        raise ValueError("Final runtime text differs from the TUI model")
    return dict(passed=True, workload=WORKLOAD, write_mode=write_mode, sequence=sequence, columns=columns, rows=rows,
                text_sha256=hashlib.sha256(text.encode()).hexdigest(),
                scope="Exact final runtime text only. Does not verify cell styles, all intermediate drawable pixels, cadence or native120.")


def finish(directory, mode, reader, sequence):
    directory = Path(directory)
    result_path = directory / "result.json"
    if not result_path.exists():
        return
    native = json.loads(result_path.read_text())
    if native.get("failed") != 0:
        return
    report = dict(passed=False)
    try:
        trace = json.loads((directory / "tui-trace.json").read_text())
        primary = int((directory / "primary.claim").read_text())
        if trace.get("pid") != primary:
            raise ValueError("TUI receipt belongs to another producer")
        pane, rows = str(trace["pane_id"]), str(trace["rows"])
        socket = str(directory / "runtime.sock")
        if mode != "gui-cpp":
            raise ValueError("TUI screen oracle requires a complete Telar stack")
        command = [str(reader), socket, pane, str(trace["pane_generation"]), rows]
        actual = subprocess.check_output(command, text=True, timeout=20)
        (directory / "runtime-screen.txt").write_text(actual)
        report = validate_screen(trace, actual, sequence)
        report["command"] = command
    except Exception as error:
        report["error"] = repr(error)
        raise
    finally:
        (directory / "screen-oracle.json").write_text(json.dumps(report, indent=2) + "\n")
        native["tui_validation"] = report
        native["foreground_workload"] = WORKLOAD
        result_path.write_text(json.dumps(native, indent=2) + "\n")
