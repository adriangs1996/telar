import math
import unittest

from tab_switch_fixture import PUBLICATION
from tab_switch_report import publication_events, validate_switch


def example():
    events = [PUBLICATION.pack(index + 1, 10 + index / 30, 10 + index / 30 + .00001) for index in range(121)]
    receipts = [dict(tab_index=tab, identities=dict(TELAR_PANE_ID=tab + 1, TELAR_TAB_ID=tab + 10,
                                                   TELAR_WORKSPACE_ID=1), error=None,
                     offered_updates_per_second=30, generation=121, publications=121) for tab in range(4)]
    samples = []
    for index in range(8):
        at = 11.01 + index * .15
        minimum = int((at - 10) * 30) + 1
        samples.append(dict(target_tab=3 - index % 4, observed_tab=3 - index % 4,
                            minimum_generation=minimum, observed_generation=minimum + 1,
                            input_at=at, presented_at=at + .05))
    return dict(interaction='previous_tab', switch_samples=samples), receipts, {tab: b''.join(events) for tab in range(4)}


class SwitchReportTest(unittest.TestCase):
    def test_phase_delivery_requires_its_receipt_and_bounded_lateness(self):
        result, receipts, events = example()
        with self.assertRaisesRegex(ValueError, 'producer phase'):
            validate_switch(result, receipts, events, require_phase=True)
        start = result['switch_samples'][0]['input_at']
        phase = dict(policy='widest_producer_gap', deadline=start - .001, clearance=.008)
        result['initial_phase'] = phase
        self.assertEqual(validate_switch(result, receipts, events, require_phase=True)['initial_phase'], phase)
        for field, value in [('policy', 'unknown'), ('deadline', start + .001),
                             ('deadline', start - .005), ('deadline', math.nan),
                             ('clearance', 0), ('clearance', 1), ('clearance', math.inf)]:
            result['initial_phase'] = dict(phase, **{field: value})
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, 'producer phase'):
                validate_switch(result, receipts, events, require_phase=True)

    def test_verified_targets_have_provenance_and_all_four_producers(self):
        result, receipts, events = example()
        report = validate_switch(result, receipts, events)
        self.assertTrue(report['verified_target_generations'])
        self.assertEqual(report['publications_by_tab'], {tab: [15, 15] for tab in range(4)})

    def test_wrong_stale_unpublished_and_reordered_frames_are_rejected(self):
        for field, value in [('observed_tab', 0), ('observed_generation', 1),
                             ('observed_generation', 120), ('minimum_generation', 0),
                             ('input_at', 10), ('presented_at', float('nan'))]:
            result, receipts, events = example()
            result['switch_samples'][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate_switch(result, receipts, events)
        result, receipts, events = example()
        result['switch_samples'][4]['minimum_generation'] = result['switch_samples'][0]['observed_generation']
        with self.assertRaises(ValueError):
            validate_switch(result, receipts, events)

    def test_duplicate_runtime_identities_are_rejected(self):
        result, receipts, events = example()
        receipts[1]['identities']['TELAR_TAB_ID'] = receipts[0]['identities']['TELAR_TAB_ID']
        with self.assertRaisesRegex(ValueError, 'runtime pane/tab'):
            validate_switch(result, receipts, events)

    def test_publication_files_require_complete_monotonic_records(self):
        _, _, streams = example()
        for data in (b'', streams[0][:-1], streams[0][PUBLICATION.size:],
                     PUBLICATION.pack(1, 10, 9), PUBLICATION.pack(1, 10, float('inf'))):
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                publication_events(data)

    def test_a_producer_stall_cannot_hide_behind_a_valid_presented_target(self):
        result, receipts, streams = example()
        result['switch_samples'] = result['switch_samples'][:2]
        result['switch_samples'][1].update(input_at=12.01, presented_at=12.06,
                                           minimum_generation=61, observed_generation=62)
        events = publication_events(streams[0])
        streams[0] = b''.join(PUBLICATION.pack(generation, before + (.2 if generation >= 31 else 0),
                                             after + (.2 if generation >= 31 else 0))
                              for generation, before, after in events)
        with self.assertRaisesRegex(ValueError, '5% offered-rate'):
            validate_switch(result, receipts, streams)


if __name__ == '__main__':
    unittest.main()
