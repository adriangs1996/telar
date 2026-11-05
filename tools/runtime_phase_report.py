"""Validate diagnostic runtime counters partitioned by native scroll actions.

This decomposes the outer runtime-resource window; it does not change its
acceptance meaning or turn observer timings into performance measurements.
"""

import argparse
import json
import math
from pathlib import Path

from native_runtime_resources import interval


CLOCK_TOLERANCE_SECONDS = 1e-6


def summarize(outer, phase, result):
    if outer.get('errors') or not outer['cleanup']['cleanup_complete'] or result['failed']:
        raise ValueError('Invalid runtime cleanup or GUI run')
    if not result['scroll_validation']['passed']:
        raise ValueError('Unqualified scroll content')
    warmup, count = result['warmup'], result['summary']['n']
    samples = result['scroll_samples']
    if type(warmup) is not int or type(count) is not int or warmup < 1 or count < 1 or len(samples) != warmup + count:
        raise ValueError('Incomplete measured action interval')
    if len(phase['snapshots']) != 3:
        raise ValueError('Expected three runtime phase snapshots')
    ready, start, end = phase['snapshots']
    bounds = [phase[name] for name in ('ready_ca_before', 'ready_ca_after', 'start_ca_before', 'start_ca_after', 'end_ca_before', 'end_ca_after')]
    if any(type(value) not in (int, float) or not math.isfinite(value) or value <= 0 for value in bounds) or bounds != sorted(bounds):
        raise ValueError('Invalid native phase clock')
    for snapshot, before, after in ((ready, bounds[0], bounds[1]), (start, bounds[2], bounds[3]), (end, bounds[4], bounds[5])):
        if not before - CLOCK_TOLERANCE_SECONDS <= snapshot['before_ns'] / 1e9 <= snapshot['after_ns'] / 1e9 <= after + CLOCK_TOLERANCE_SECONDS:
            raise ValueError('Resource clock does not match native clock brackets')
    for index, sample in enumerate(samples):
        a, b = sample['input_at'], sample['presented_at']
        if any(type(value) not in (int, float) or not math.isfinite(value) or value <= 0 for value in (a, b)) or a > b:
            raise ValueError('Invalid action/presentation clock')
        if index and samples[index - 1]['presented_at'] > a:
            raise ValueError('Overlapping discrete actions')
    if samples[0]['input_at'] < bounds[1] or samples[warmup - 1]['presented_at'] > bounds[2] or samples[warmup]['input_at'] < bounds[3] or samples[-1]['presented_at'] > bounds[4]:
        raise ValueError('Resource phase does not cover exactly the measured actions')
    if start['pid'] != outer['identity']['pid']:
        raise ValueError('Runtime PID differs from the socket-verified process')
    points = [outer['start'], ready, start, end, outer['end']]
    names = ('setup', 'warmup', 'measured_inputs', 'after_measurement')
    phases = {name: interval(points[index], points[index + 1]) for index, name in enumerate(names)}
    whole = interval(points[0], points[-1])
    for key in ('user_cpu_seconds', 'system_cpu_seconds', 'idle_wakeups', 'interrupt_wakeups', 'pageins', 'instructions', 'cycles'):
        if key in whole:
            total = sum(value[key] for value in phases.values())
            matches = total == whole[key] if type(whole[key]) is int else math.isclose(total, whole[key], rel_tol=1e-12, abs_tol=1e-12)
            if not matches:
                raise ValueError(f'Phase accounting is not additive: {key}')
    cpu = whole['user_cpu_seconds'] + whole['system_cpu_seconds']
    measured = phases['measured_inputs']
    measured_cpu = measured['user_cpu_seconds'] + measured['system_cpu_seconds']
    return dict(scope='Diagnostic only; three runtime queries separate setup, warmup and native measured inputs. Timings cannot establish acceptance.',
                valid=True, measured_inputs=count, warmup=warmup, phases=phases, whole=whole,
                measured_cpu_fraction=None if cpu == 0 else measured_cpu / cpu)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    def read(name):
        return json.loads((args.directory / name).read_text())
    report = summarize(read('runtime-resources.json'), read('runtime-phase.json'), read('result.json'))
    with args.output.open('x') as output:
        output.write(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
