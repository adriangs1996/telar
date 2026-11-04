"""Validate exact row identities after discrete native upward wheel events.

The caller separately verifies native presentation, focus, geometry, VSync,
process ownership, host load and cleanup. This is not continuous F06 acceptance.
"""

import hashlib
import math

from scroll_bench_fixture import CORPUS_ROWS, ROWS_PER_INPUT, corpus


def validate_scroll(result, receipt, primary_pid):
    samples = result.get('scroll_samples')
    warmup = result.get('warmup')
    if (result.get('interaction') != 'scroll_up' or result.get('endpoint') != 'presented' or
            result.get('input_method') != 'native_discrete_wheel' or
            not isinstance(samples, list) or not samples or
            type(warmup) is not int or not 0 <= warmup < len(samples)):
        raise ValueError('missing native scroll observations')
    for name in ('pid', 'cols', 'rows', 'initial_top_row', 'geometry_generation', 'payload_bytes'):
        if type(receipt.get(name)) is not int or receipt[name] <= 0:
            raise ValueError('invalid scroll fixture identity or geometry')
    if (type(receipt.get('version')) is not int or receipt['version'] != 1 or receipt.get('phase') != 'ready' or
            receipt['pid'] != primary_pid or receipt.get('corpus_rows') != CORPUS_ROWS or
            receipt.get('rows_per_input') != ROWS_PER_INPUT or
            receipt['rows'] >= CORPUS_ROWS or result.get('pty_cells') != [receipt['cols'], receipt['rows']]):
        raise ValueError('scroll fixture does not match the native workload')
    payload = corpus(receipt['cols'])
    if (len(payload) != receipt['payload_bytes'] or
            hashlib.sha256(payload).hexdigest() != receipt.get('payload_sha256')):
        raise ValueError('scroll corpus receipt differs from the deterministic payload')
    top = CORPUS_ROWS - receipt['rows'] + 1
    if (receipt['initial_top_row'] != top or result.get('scroll_initial_top_row') != top or
            result.get('scroll_rows_per_input') != ROWS_PER_INPUT or
            top <= ROWS_PER_INPUT * len(samples)):
        raise ValueError('scroll origin or extent is invalid')
    durations = result.get('presentation_ms')
    if not isinstance(durations, list) or len(durations) != len(samples):
        raise ValueError('scroll presentation lengths differ')
    previous = 0
    for index, (sample, duration) in enumerate(zip(samples, durations), 1):
        if not isinstance(sample, dict):
            raise ValueError('invalid scroll sample')
        expected = top - ROWS_PER_INPUT * index
        if (type(sample.get('expected_row')) is not int or type(sample.get('observed_row')) is not int or
                sample['expected_row'] != expected or sample['observed_row'] != expected):
            raise ValueError('stale, skipped or wrong visible row')
        begin, presented = sample.get('input_at'), sample.get('presented_at')
        if (any(type(value) not in (int, float) or not math.isfinite(value) or value <= 0
                for value in (begin, presented, duration)) or
                not previous < begin < presented or
                not math.isclose((presented - begin) * 1000, duration, rel_tol=0, abs_tol=1e-6)):
            raise ValueError('invalid or inconsistent scroll presentation timestamps')
        previous = presented
    return dict(passed=True, samples=len(samples) - warmup, warmup=warmup,
                initial_top_row=top, final_top_row=expected, rows_per_input=ROWS_PER_INPUT,
                scope='Exact top-row packet per presented input. Does not certify all body pixels, selection, return-to-live, live-output scrolling or continuous native120.')
