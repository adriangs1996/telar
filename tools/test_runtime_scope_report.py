import copy
import unittest

from runtime_scope_report import attribute, summarize, validate_trace
from prepare_runtime_scope_overlay import replace_once
import test_runtime_phase_report as phase_tests


def record(name, start, end, thread=1, work=1):
    return dict(name=name, begin_ns=start, end_ns=end, thread=thread, work=work, kind=0, object=0)


class RuntimeScopeTests(unittest.TestCase):
    def test_instrumentation_anchors(self):
        self.assertEqual(replace_once('before anchor after', 'anchor', 'new'), 'before new after')
        for source in ('missing', 'anchor twice anchor'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                replace_once(source, 'anchor', 'new')

    def test_nested_exclusive_clipping_and_work(self):
        records = [record('leaf', 40, 60, work=7), record('child', 20, 80, work=5), record('parent', 0, 100, work=9)]
        groups = {g['name']: g for g in attribute(records, [('phase', 30, 90)])['phase']['groups']}
        self.assertEqual(groups['parent']['exclusive_elapsed_ns'], 10)
        self.assertEqual(groups['child']['exclusive_elapsed_ns'], 30)
        self.assertEqual(groups['leaf']['exclusive_elapsed_ns'], 20)
        self.assertEqual(groups['child']['contained_work'], 0)
        self.assertEqual(groups['leaf']['contained_work'], 7)
        self.assertEqual(groups['parent']['boundary_crossing_count'], 1)

    def test_threads_ties_zero_duration_and_adjacent_scopes(self):
        records = [record('child', 10, 20), record('parent', 10, 20), record('other', 15, 25, thread=2),
                   record('zero', 16, 16), record('adjacent', 20, 30)]
        groups = {g['name']: g for g in attribute(records, [('phase', 1, 40)])['phase']['groups']}
        self.assertEqual(groups['parent']['exclusive_elapsed_ns'], 0)
        self.assertEqual(groups['child']['exclusive_elapsed_ns'], 10)
        self.assertEqual(groups['other']['exclusive_elapsed_ns'], 10)
        self.assertEqual(groups['adjacent']['exclusive_elapsed_ns'], 10)

    def test_crossing_and_window_rejections(self):
        with self.assertRaises(ValueError):
            attribute([record('a', 10, 30), record('b', 20, 40)], [('phase', 1, 50)])
        for windows in [[('a', 20, 10)], [('a', 1, 30), ('b', 20, 40)], [('a', 1, 20), ('a', 30, 40)]]:
            with self.subTest(windows=windows), self.assertRaises(ValueError):
                attribute([], windows)

    def test_trace_rejections(self):
        header = dict(pid=42, clock='CLOCK_UPTIME_RAW ns', count=1, capacity=10, dropped=0)
        records = [record('a', 1, 2)]
        validate_trace(header, records, 42)
        for key, value in dict(pid=43, clock='wall', count=2, capacity=0, dropped=1).items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_trace(dict(header, **{key: value}), records, 42)
        for key, value in dict(begin_ns=3, end_ns=-1, thread=0, work=True, kind=2**64, object=1.0, name='bad\nname').items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_trace(header, [dict(records[0], **{key: value})], 42)
        with self.assertRaises(ValueError):
            validate_trace(dict(header, count=0), [], 42)

    def test_qualified_phases_and_missing_lifetime(self):
        fixture = phase_tests.RuntimePhaseTests()
        fixture.setUp()
        header = dict(pid=42, clock='CLOCK_UPTIME_RAW ns', count=1, capacity=10, dropped=0)
        records = [record('runtime.run', 1, 100 * 10**9)]
        result = summarize(fixture.outer, fixture.phase, fixture.result, header, records)
        self.assertTrue(result['valid'])
        measured = result['phases']['measured_inputs']
        self.assertEqual(measured['start_ns'], 21 * 10**9)
        self.assertEqual(measured['end_ns'], 80 * 10**9)
        for key, value in [('name', 'unrelated'), ('end_ns', 50 * 10**9)]:
            invalid = copy.deepcopy(records)
            invalid[0][key] = value
            with self.assertRaises(ValueError):
                summarize(fixture.outer, fixture.phase, fixture.result, header, invalid)


if __name__ == '__main__':
    unittest.main()
