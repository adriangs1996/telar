import copy
import unittest

from thread_cpu_report import analyze


def thread(identity, cpu):
    return dict(id=identity, user_us=cpu, system_us=0, identifier_result=0,
                basic_result=0, name_result=0, name_hex="74657374")


def snapshot(index, kind, process, rows):
    return dict(type="snapshot", kind=kind, sequence=index, sampler_id=1,
                before_ns=1000 + index * 1000, after_ns=1100 + index * 1000,
                process_before_us=[process, 0], process_after_us=[process + 1, 0],
                enumeration_result=0, enumerated=len(rows), threads=rows)


def capture():
    return [dict(type="header", version=1, pid=12, controlling_id=1,
                 cpu_unit="microseconds", clock="CLOCK_UPTIME_RAW"),
            snapshot(0, "begin", 100, [thread(1, 40), thread(2, 60)]),
            snapshot(1, "periodic", 125, [thread(1, 50), thread(2, 70), thread(3, 5)]),
            snapshot(2, "end", 140, [thread(1, 60), thread(2, 75)]),
            dict(type="footer", observer_error=0, join_error=0, end_error=0)]


class ThreadCpuReportTest(unittest.TestCase):
    def test_retired_and_new_threads_leave_visible_residual(self):
        result = analyze(capture())
        self.assertAlmostEqual(result["observed_thread_cpu_ms"], 0.040)
        self.assertAlmostEqual(result["signed_residual_minimum_ms"], -0.001)
        retired = next(row for row in result["threads"] if row["id"] == 3)
        self.assertFalse(retired["present_at_begin"])
        self.assertFalse(retired["present_at_end"])
        self.assertEqual(retired["cpu_ms"], 0.005)

    def test_completely_unseen_cpu_is_not_assigned_to_live_threads(self):
        data = capture()
        data[-2]["process_before_us"][0] += 100
        data[-2]["process_after_us"][0] += 100
        result = analyze(data)
        self.assertAlmostEqual(result["observed_thread_cpu_ms"], 0.040)
        self.assertAlmostEqual(result["signed_residual_minimum_ms"], 0.099)

    def test_negative_controls(self):
        controls = [
            ("footer", lambda rows: rows.pop()),
            ("units", lambda rows: rows[0].update(cpu_unit="ticks")),
            ("reordered snapshot", lambda rows: rows[2].update(sequence=3)),
            ("clock", lambda rows: rows[2].update(before_ns=0)),
            ("enumeration", lambda rows: rows[2].update(enumerated=99)),
            ("thread observation", lambda rows: rows[2]["threads"][0].update(basic_result=5)),
            ("duplicate", lambda rows: rows[2]["threads"][1].update(id=1)),
            ("decreasing thread", lambda rows: rows[2]["threads"][0].update(user_us=1)),
            ("decreasing process", lambda rows: rows[2].update(process_before_us=[1, 0])),
            ("observer failed", lambda rows: rows[-1].update(observer_error=5)),
            ("snapshot kind", lambda rows: rows[2].update(kind="begin")),
            ("controlling thread", lambda rows: rows[0].update(controlling_id=100)),
            ("sampler absent", lambda rows: rows[2].update(sampler_id=100)),
            ("boundary thread mismatch", lambda rows: rows[-2].update(sampler_id=2)),
        ]
        for message, mutate in controls:
            with self.subTest(message=message):
                data = copy.deepcopy(capture())
                mutate(data)
                with self.assertRaisesRegex(ValueError, message):
                    analyze(data)


if __name__ == "__main__":
    unittest.main()
