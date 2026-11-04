"""Validate tab targets, generation provenance and offered work for native runs.

The caller must also run the native harness's presentation, focus, geometry and
VSync checks. This module does not qualify continuous frame cadence or 120 Hz.
"""
import math

from tab_switch_fixture import PUBLICATION, TAB_COUNT, UPDATES_PER_SECOND


def stage_samples(result):
    """Decompose already-qualified observations without changing the endpoint.

    Completion is the native command-buffer callback, not GPU execution end.
    Presentation minus callback can be negative because callbacks can run late.
    GPU work is a separate overlapping interval. Neither it nor stage quantiles
    may be added to the other reported durations. The caller still qualifies
    native presentation, producers, host load and cleanup before interpretation.
    """
    switches = result.get('switch_samples')
    warmup = result.get('warmup')
    fields = ('gpu_ms', 'presentation_ms', 'gpu_work_ms')
    arrays = [result.get(name) for name in fields]
    if (result.get('interaction') != 'previous_tab' or result.get('endpoint') != 'presented'
            or not isinstance(switches, list) or not switches
            or any(not isinstance(sample, dict) for sample in switches)
            or type(warmup) is not int or not 0 <= warmup < len(switches)
            or any(not isinstance(values, list) or len(values) != len(switches) for values in arrays)):
        raise ValueError('incomplete tab-switch stage observations')
    if any(type(value) not in (int, float) or not math.isfinite(value) or value < 0
           for values in arrays for value in values):
        raise ValueError('invalid tab-switch stage duration')
    for sample, presented in zip(switches, arrays[1]):
        times = [sample.get(name) for name in ('input_at', 'presented_at')]
        if (any(type(value) not in (int, float) or not math.isfinite(value) or value <= 0 for value in times)
                or times[1] <= times[0]
                or not math.isclose((times[1] - times[0]) * 1000, presented, rel_tol=0, abs_tol=1e-6)):
            raise ValueError('tab-switch stage timestamps disagree')
    callback, presented, work = (values[warmup:] for values in arrays)
    return dict(input_to_completion_callback_ms=callback,
                presentation_minus_callback_ms=[end - start for start, end in zip(callback, presented)],
                gpu_execution_ms=work, input_to_presentation_ms=presented)


def publication_events(data):
    if not data or len(data) % PUBLICATION.size:
        raise ValueError('missing or truncated publication events')
    events = list(PUBLICATION.iter_unpack(data))
    previous = 0
    for expected, (generation, before, after) in enumerate(events, 1):
        if (generation != expected or not all(math.isfinite(value) for value in (before, after))
                or before <= previous or after < before):
            raise ValueError('invalid publication generation or native clock')
        previous = after
    return events


def validate_switch(result, receipts, publications, *, require_phase=False):
    samples = result.get('switch_samples', [])
    if result.get('interaction') != 'previous_tab' or not samples or len(receipts) != TAB_COUNT:
        raise ValueError('missing native tab-switch observations')
    if {r['tab_index'] for r in receipts} != set(range(TAB_COUNT)):
        raise ValueError('missing or duplicate tab identities')
    for name in ('TELAR_PANE_ID', 'TELAR_TAB_ID'):
        identities = [r['identities'][name] for r in receipts]
        if len(set(identities)) != TAB_COUNT or any(type(value) is not int or value <= 0 for value in identities):
            raise ValueError('invalid runtime pane/tab identities')
    if len({r['identities']['TELAR_WORKSPACE_ID'] for r in receipts}) != 1:
        raise ValueError('tab workload spans unexpected workspaces')
    events = {tab: publication_events(data) for tab, data in publications.items()}
    if set(events) != set(range(TAB_COUNT)):
        raise ValueError('missing producer publication stream')
    last_seen = [0] * TAB_COUNT
    previous_presented = 0
    for index, sample in enumerate(samples):
        tab = TAB_COUNT - 1 - index % TAB_COUNT
        minimum, generation = sample['minimum_generation'], sample['observed_generation']
        input_at, presented = sample['input_at'], sample['presented_at']
        if (sample['target_tab'] != tab or sample['observed_tab'] != tab
                or not all(type(value) is int for value in (minimum, generation))
                or not 0 < minimum <= generation <= len(events[tab])
                or minimum <= last_seen[tab]
                or not all(math.isfinite(value) for value in (input_at, presented))
                or not previous_presented < input_at <= presented
                or events[tab][minimum - 1][2] > input_at
                or events[tab][generation - 1][2] > presented):
            raise ValueError('wrong/stale/unpublished target or invalid presentation order')
        last_seen[tab] = generation
        previous_presented = presented
    start, end = samples[0]['input_at'], samples[-1]['presented_at']
    phase = result.get('initial_phase')
    if require_phase or phase is not None:
        if (not isinstance(phase, dict) or phase.get('policy') != 'widest_producer_gap'
                or not all(isinstance(phase.get(key), (int, float)) and math.isfinite(phase[key])
                           for key in ('deadline', 'clearance'))
                or not 0 < phase['deadline'] <= start
                or not 0 < phase['clearance'] <= .5 / UPDATES_PER_SECOND
                or start - phase['deadline'] > phase['clearance'] / 2):
            raise ValueError('first input missed the declared producer phase')
    checkpoint_seconds = .5
    checkpoints = int((end - start) / checkpoint_seconds)
    if checkpoints < 1:
        raise ValueError('too few complete offered-rate checkpoints')
    rate = {}
    for tab, events_for_tab in events.items():
        receipt = next(r for r in receipts if r['tab_index'] == tab)
        if (receipt['error'] is not None or receipt['offered_updates_per_second'] != UPDATES_PER_SECOND
                or receipt['generation'] != receipt['publications'] or receipt['publications'] > len(events_for_tab)
                or events_for_tab[0][2] > start or events_for_tab[-1][2] < end):
            raise ValueError('producer failed or does not cover the observation window')
        counts = [sum(start + i * checkpoint_seconds <= event[2] < start + (i + 1) * checkpoint_seconds
                      for event in events_for_tab) for i in range(checkpoints)]
        expected = UPDATES_PER_SECOND * checkpoint_seconds
        if any(abs(count / expected - 1) > .05 for count in counts):
            raise ValueError('producer missed the unchanged 5% offered-rate tolerance')
        rate[tab] = counts
    return dict(verified_target_generations=True, publication_clock='CACurrentMediaTime',
                offered_updates_per_second=UPDATES_PER_SECOND, checkpoint_seconds=checkpoint_seconds,
                complete_checkpoints=checkpoints, publications_by_tab=rate,
                observation_start=start, observation_end=end, initial_phase=phase)
