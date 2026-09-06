import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import echo_path
import echo_trace
import echo_tail
import perf_e2e


class Oracle:
    def __init__(self, states):
        self.states = iter(states)
        self.count = 0
        self.synchronized = False

    def feed(self, data):
        self.count, self.synchronized = next(self.states)


class EchoToolsTest(unittest.TestCase):
    def test_binary_pairs_remain_adjacent_and_alternate_with_or_without_controls(self):
        controls = [(name, None) for name in ['direct', 'one', 'two']]
        binaries = [('baseline', '/base'), ('candidate', '/candidate')]
        for count in range(4):
            for repetition in range(8):
                order = echo_path.ordered_specs(controls[:count] + binaries, repetition)
                names = [name for name, _ in order]
                first = names.index('candidate' if repetition % 2 else 'baseline')
                second = names.index('baseline' if repetition % 2 else 'candidate')
                self.assertEqual(second, first + 1)
                self.assertEqual(set(order), set(controls[:count] + binaries))

    def test_old_repaint_and_uncommitted_change_do_not_complete_echo(self):
        chunks = [b'old repaint', b'new but synchronized', b'commit']
        oracle = Oracle([(1, False), (2, True), (2, False)])
        with (patch.object(echo_path.os, 'write') as write,
              patch.object(echo_path.os, 'read', side_effect=chunks),
              patch.object(echo_path.select, 'select', return_value=([7], [], [])),
              patch.object(echo_path.time, 'perf_counter', return_value=0),
              patch.object(echo_path.time, 'perf_counter_ns', side_effect=[0, 10, 100, 200, 300])):
            result = echo_path.exchange(7, oracle, b'~', 2)
        write.assert_called_once_with(7, b'~')
        self.assertEqual(result, dict(us=.3, reads=3, wire_bytes=sum(map(len, chunks)),
                                      started_ns=0, sent_ns=10, arrived_ns=300))

    def test_tail_cpu_deltas_require_the_same_process_and_thread(self):
        start = dict(event='start', ns=1000, cpu_ns=500, process='client', thread=7)
        end = dict(event='end', ns=2000, cpu_ns=750, process='client', thread=7)
        self.assertEqual(echo_tail.phase(start, end)['wall_minus_cpu_us'], .75)
        for field, value in [('process', 'runtime'), ('thread', 8)]:
            self.assertNotIn('cpu_us', echo_tail.phase(start, dict(end, **{field: value})))

    def test_tail_analysis_preserves_clock_residuals_and_rejects_wrong_chains(self):
        start = dict(event='start', ns=1000, cpu_ns=500, process='client', thread=7)
        end = dict(event='end', ns=1100, cpu_ns=650, process='client', thread=7)
        self.assertLess(echo_tail.phase(start, end)['wall_minus_cpu_us'], 0)
        sample = dict(us=1, started_ns=1000, sent_ns=1010, arrived_ns=2000)
        self.assertEqual(echo_tail.correlate(sample, [start, end])['total_us'], 1)
        with self.assertRaises(ValueError):
            echo_tail.correlate(sample, [dict(start, ns=999), end])
        with self.assertRaises(ValueError):
            echo_tail.correlate(dict(sample, us=2), [start, end])

    def test_send_spans_do_not_confuse_peer_wait_with_sender_execution(self):
        events = [
            dict(event='client_send_start', ns=1000, cpu_ns=100, process='client', thread=3),
            dict(event='runtime_read', ns=1100, cpu_ns=500, process='runtime', thread=3),
            dict(event='client_send_done', ns=2000, cpu_ns=150, process='client', thread=3),
        ]
        spans = echo_tail.send_spans(events)
        self.assertEqual(len(spans), 1)
        self.assertAlmostEqual(spans[0]['cpu_us'], .05)
        self.assertAlmostEqual(spans[0]['wall_minus_cpu_us'], .95)

    def test_tail_gap_is_measured_without_raising_the_median(self):
        result = echo_tail.percentiles([100, 100, 100, 1000])
        self.assertAlmostEqual(result['tail_gap_us'], result['p99_us'] - 100)

    def test_cleanup_rejects_runner_session_before_signalling_anyone(self):
        with patch.object(perf_e2e.os, 'kill') as kill:
            with self.assertRaises(RuntimeError):
                perf_e2e.cleanup_sessions({os.getsid(0)})
        kill.assert_not_called()

    def test_trace_summary_excludes_warmup_and_immediate_erases(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            rows = []
            for index in range(46):
                step = 10 if index % 2 == 0 else 1000
                rows += [dict(ns=index * 100000 + offset * step, event=tag)
                         for offset, tag in enumerate(echo_trace.CHAIN)]
            rows.append(dict(ns=46 * 100000, event='host_read'))
            for part in range(2):
                data = rows[part::2] + [dict(dropped=0)]
                (directory / f'{part}.echo.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in data))
            echo = echo_trace.summarize(directory)['internal_total']
            erase = echo_trace.summarize(directory, erase=True)['internal_total']
            self.assertEqual(echo['n'], 3)
            self.assertAlmostEqual(echo['p50_us'], (len(echo_trace.CHAIN) - 1) * .01)
            self.assertAlmostEqual(erase['p50_us'], echo['p50_us'] * 100)

    def test_trace_summary_rejects_missing_process(self):
        with tempfile.TemporaryDirectory() as name:
            with self.assertRaises(ValueError):
                echo_trace.summarize(Path(name))


if __name__ == '__main__':
    unittest.main()
