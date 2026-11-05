from contextlib import ExitStack
import os
import unittest
from unittest.mock import patch

from terminal_bench_fixture import write_all
from tui_bench_fixture import TuiFixture
from tui_bench_trace import Trace
from tui_coalesced_fixture import CoalescedTuiFixture


def fixture(kind):
    result = object.__new__(kind)
    result.trace = Trace()
    result.primary = True
    result.marker_inputs = 0
    result.color = 0
    result.capture_marker = False
    result.record_trace = lambda: None
    return result


def capture(instance, action, short_write=None):
    buffers = []
    pieces = []

    def observe(data):
        buffers.append(bytes(data))
        if short_write is not None:
            write_all(data)

    def write(descriptor, data):
        assert descriptor == 1
        amount = min(len(data), short_write)
        pieces.append(bytes(data[:amount]))
        return amount

    with ExitStack() as stack:
        for module in ('terminal_bench_fixture', 'tui_bench_fixture', 'tui_coalesced_fixture'):
            stack.enter_context(patch(module + '.write_all', observe))
        if short_write is not None:
            stack.enter_context(patch('terminal_bench_fixture.os.write', write))
        action(instance)
    if short_write is not None:
        assert b''.join(pieces) == b''.join(buffers)
    return buffers


class CoalescedFixtureTest(unittest.TestCase):
    def test_identical_bytes_and_model_across_resize_capture_and_input(self):
        original, coalesced = fixture(TuiFixture), fixture(CoalescedTuiFixture)
        keys = [b'c', b'r'] + [b'x'] * 97 + [b'c', b'x', b'r']
        for size in ((1, 1), (39, 19), (82, 21), (120, 40), (82, 21)):
            for item in (original, coalesced):
                item.size = os.terminal_size(size)
            for key in keys:
                left = capture(original, lambda item: item.handle_marker_input(key))
                right = capture(coalesced, lambda item: item.handle_marker_input(key))
                self.assertEqual(b''.join(left), b''.join(right))
                self.assertEqual(len(left), 4 if key == b'c' else 3)
                self.assertEqual(len(right), 2 if key == b'c' else 1)
                self.assertEqual(original.trace.receipt(), coalesced.trace.receipt())

    def test_short_writes_preserve_all_bytes(self):
        for limit in (1, 7, 257):
            original, coalesced = fixture(TuiFixture), fixture(CoalescedTuiFixture)
            for item in (original, coalesced):
                item.size = os.terminal_size((82, 21))
                item.marker_inputs = 31
                item.color = 1
            left = capture(original, lambda item: item.handle_marker_input(b'x'), limit)
            right = capture(coalesced, lambda item: item.handle_marker_input(b'x'), limit)
            self.assertEqual(b''.join(left), b''.join(right))


if __name__ == '__main__':
    unittest.main()
