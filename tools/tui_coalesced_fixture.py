"""Diagnostic-only TUI producer: coalesce each draw's three output buffers.

The application and bytes are unchanged, but producer write boundaries differ.
This workload must not enter ordinary TUI timing acceptance. A write_all call can
still require multiple os.write calls or be split across the consumer's reads.
"""

import argparse
import os
from pathlib import Path

from terminal_bench_fixture import atomic_json, defer_resize, write_all
from tui_bench_fixture import TuiFixture


class CoalescedTuiFixture(TuiFixture):
    def draw_marker(self):
        with defer_resize():
            body = self.trace.draw(self.size.columns, self.size.lines, self.marker_inputs, self.capture_marker)
            rgb = '230;20;60' if self.color == 0 else '20;220;200'
            if self.capture_marker:
                rgb = '180;180;180'
            marker = (f'\x1b[?25l\x1b[{min(8, self.size.lines)};'
                      f'{min(20, self.size.columns)}H\x1b[48;2;{rgb}m '
                      '\x1b[0m\x1b[H').encode('ascii')
            column = 1 + self.marker_inputs % max(1, self.size.columns - 1)
            cursor = f'\x1b[{self.size.lines};{column}H\x1b[?25h'.encode('ascii')
            write_all(body + marker + cursor)
            self.record_trace()

    def record_trace(self):
        receipt = self.trace.receipt()
        if receipt is not None:
            receipt.update(pid=self.pid, pane_id=int(os.environ['TELAR_PANE_ID']),
                           pane_generation=int(os.environ['TELAR_PANE_GENERATION']),
                           write_mode='coalesced')
            atomic_json(self.directory / 'tui-trace.json', receipt)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    CoalescedTuiFixture(parser.parse_args().directory.resolve()).run()
