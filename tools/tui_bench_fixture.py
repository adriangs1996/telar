"""Native-marker fixture with full and partial ASCII TUI updates before the marker."""

import argparse
import os
from pathlib import Path

from terminal_bench_fixture import Fixture, atomic_json, defer_resize, write_all
from tui_bench_trace import Trace


class TuiFixture(Fixture):
    def __init__(self, directory):
        super().__init__(directory)
        self.trace = Trace()

    def draw_marker(self):
        with defer_resize():
            write_all(self.trace.draw(self.size.columns, self.size.lines, self.marker_inputs, self.capture_marker))
            super().draw_marker()
            # Keep the native marker intact while exercising a visible, moving cursor.
            column = 1 + self.marker_inputs % max(1, self.size.columns - 1)
            write_all(f"\x1b[{self.size.lines};{column}H\x1b[?25h".encode("ascii"))
            self.record_trace()

    def record_trace(self):
        receipt = self.trace.receipt()
        if receipt is not None:
            receipt.update(pid=self.pid, pane_id=int(os.environ["TELAR_PANE_ID"]),
                           pane_generation=int(os.environ["TELAR_PANE_GENERATION"]))
            atomic_json(self.directory / "tui-trace.json", receipt)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    TuiFixture(parser.parse_args().directory.resolve()).run()
