import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import echo_path
import echo_trace
import perf_e2e


class Oracle:
    def __init__(self, states):
        self.states = iter(states)
        self.count = 0
        self.synchronized = False

    def feed(self, data):
        self.count, self.synchronized = next(self.states)


class EchoToolsTest(unittest.TestCase):
    def test_old_repaint_and_uncommitted_change_do_not_complete_echo(self):
        chunks = [b'old repaint', b'new but synchronized', b'commit']
        oracle = Oracle([(1, False), (2, True), (2, False)])
        with (patch.object(echo_path.os, 'write') as write,
              patch.object(echo_path.os, 'read', side_effect=chunks),
              patch.object(echo_path.select, 'select', return_value=([7], [], [])),
              patch.object(echo_path.time, 'perf_counter', return_value=0),
              patch.object(echo_path.time, 'perf_counter_ns', side_effect=[0, 100, 200, 300])):
            result = echo_path.exchange(7, oracle, b'~', 2)
        write.assert_called_once_with(7, b'~')
        self.assertEqual(result, dict(us=.3, reads=3, wire_bytes=sum(map(len, chunks))))

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
