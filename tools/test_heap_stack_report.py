import copy
import unittest

from heap_stack_report import analyze, selected


def fixture():
    return dict(version=1, pid=12, clock='CLOCK_UPTIME_RAW', complete=True,
                begin_ns=100, end_ns=300, successful_calls=1, null_returns=0,
                free_calls=1, requested_bytes=32, api_names=['malloc', 'calloc', 'realloc', 'aligned_alloc', 'posix_memalign'],
                api_calls=[1, 0, 0, 0, 0], used=1, overflow=0, errors=0, sampling=True, sample_shift=0,
                records=[dict(ordinal=1, at_ns=200, thread_id=2, requested_bytes=32, api=0, frames=['0x1020'])],
                symbols={'0x1020': dict(resolved=True, image='/tmp/app', image_base='0x1000', symbol='site', symbol_base='0x1010')})


class HeapStackReportTest(unittest.TestCase):
    def test_exact_and_disabled_sampling(self):
        value = fixture()
        self.assertEqual(analyze(value)['first_external_symbols'], [('app:site', 1)])
        value.update(sampling=False, used=0, records=[], symbols={})
        self.assertEqual(analyze(value)['sampled_calls'], 0)

    def test_sampling_contract(self):
        self.assertTrue(all(selected(index, 0) for index in range(1, 100)))
        value = fixture()
        value.update(sample_shift=8, used=0, records=[], symbols={})
        self.assertFalse(selected(1, 8))
        self.assertEqual(analyze(value)['sampled_calls'], 0)

    def test_invalid_evidence(self):
        changes = [
            lambda x: x.update(complete=False), lambda x: x.update(overflow=1),
            lambda x: x.update(errors=1), lambda x: x.update(clock='wall'),
            lambda x: x.update(end_ns=99), lambda x: x.update(successful_calls=-1),
            lambda x: x.update(api_calls=[0] * 5), lambda x: x.update(sample_shift=13),
            lambda x: x.update(used=0), lambda x: x.update(records=[]),
            lambda x: x['records'][0].update(ordinal=2),
            lambda x: x['records'][0].update(at_ns=400),
            lambda x: x['records'][0].update(thread_id=0),
            lambda x: x['records'][0].update(api=4),
            lambda x: x['records'][0].update(requested_bytes=33),
            lambda x: x['records'][0].update(frames=[]),
            lambda x: x['records'][0].update(frames=['0x0']),
            lambda x: x['symbols']['0x1020'].update(image_base='0x2000'),
            lambda x: x.update(sampling=False),
            lambda x: x.update(requested_bytes=True),
            lambda x: x.update(version=True), lambda x: x.update(errors=False),
            lambda x: x['records'][0].update(ordinal=True),
            lambda x: x['records'][0].update(frames=['0x1020'] * 25),
        ]
        for change in changes:
            with self.subTest(change=changes.index(change)):
                value = copy.deepcopy(fixture())
                change(value)
                with self.assertRaises((ValueError, KeyError)):
                    analyze(value)


if __name__ == '__main__':
    unittest.main()
