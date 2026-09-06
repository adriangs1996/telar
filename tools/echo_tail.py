#!/usr/bin/env python3
"""Correlate echo samples with diagnostic phase clocks; never subtract CPU clocks across threads."""
import argparse
import bisect
import json
import math
from pathlib import Path

import echo_latency
import echo_trace


def percentiles(values):
    if not values:
        raise ValueError('empty latency distribution')
    result = {name: echo_latency.percentile(values, fraction)
              for name, fraction in [('p50_us', .5), ('p95_us', .95), ('p99_us', .99)]}
    result.update(n=len(values), max_us=max(values),
                  tail_gap_us=result['p99_us'] - result['p50_us'])
    return result


def phase(start, end):
    wall = (end['ns'] - start['ns']) / 1000
    if wall < 0:
        raise ValueError('non-monotonic phase')
    value = dict(name=f"{start['event']} -> {end['event']}", wall_us=wall)
    same_thread = (start['process'], start.get('thread')) == (end['process'], end.get('thread'))
    if same_thread and 'thread' in start and 'cpu_ns' in start and 'cpu_ns' in end:
        cpu = (end['cpu_ns'] - start['cpu_ns']) / 1000
        if cpu < 0:
            raise ValueError('non-monotonic thread CPU clock')
        # Preserve negative residuals: clock sampling and granularity have cost.
        value.update(cpu_us=cpu, wall_minus_cpu_us=wall - cpu)
    return value


def correlate(sample, chain):
    started = sample['started_ns']
    arrived = sample['arrived_ns']
    if not started <= sample['sent_ns'] <= arrived:
        raise ValueError('invalid stimulus timestamps')
    if not math.isclose(sample['us'], (arrived - started) / 1000, abs_tol=.001):
        raise ValueError('latency does not match timestamps')
    if not started <= chain[0]['ns'] <= arrived:
        raise ValueError('fixture chain or clock epoch does not match the stimulus')
    return dict(total_us=sample['us'], submit_us=(sample['sent_ns'] - started) / 1000,
                input_boundary_us=(chain[0]['ns'] - started) / 1000,
                output_boundary_us=(arrived - chain[-1]['ns']) / 1000,
                phases=[phase(start, end) for start, end in zip(chain, chain[1:])])


def send_spans(events):
    pending = {}
    spans = []
    for event in events:
        tag = event['event']
        if tag not in ['client_send_start', 'runtime_send_start', 'client_send_done', 'runtime_send_done']:
            continue
        key = (event['process'], event.get('thread'), tag.rsplit('_', 1)[0])
        if tag.endswith('_start'):
            pending[key] = event
        elif key in pending:
            spans.append(phase(pending.pop(key), event))
    return spans


def describe(rows):
    result = dict(latency=percentiles([row['total_us'] for row in rows]))
    for key in ['submit_us', 'input_boundary_us', 'output_boundary_us']:
        result[key] = percentiles([row[key] for row in rows])
    result['phases'] = {}
    for index, value in enumerate(rows[0]['phases']):
        group = [row['phases'][index] for row in rows]
        item = dict(wall_us=percentiles([entry['wall_us'] for entry in group]))
        cpu_rows = [entry for entry in group if 'cpu_us' in entry]
        if cpu_rows:
            item['cpu_us'] = percentiles([entry['cpu_us'] for entry in cpu_rows])
            item['wall_minus_cpu_us'] = percentiles([entry['wall_minus_cpu_us'] for entry in cpu_rows])
        result['phases'][value['name']] = item
    return result


def analyze(directory):
    results = json.loads((directory / 'results.json').read_text())
    output = []
    for run in results:
        trial = directory / f"{run['name']}-{run['repetition']}"
        chains = echo_trace.fixture_chains(trial)
        if len(chains) != len(run['samples']):
            raise ValueError(f'{trial}: missing or extra fixture chains')
        events = echo_trace.load_events(trial)
        times = [event['ns'] for event in events]
        rows = []
        for index, (sample, chain) in enumerate(zip(run['samples'], chains)):
            first = bisect.bisect_left(times, sample['started_ns'])
            last = bisect.bisect_right(times, sample['arrived_ns'])
            rows.append(dict(correlate(sample, chain), index=index,
                             sends=send_spans(events[first:last])))
        slow = sorted(rows, key=lambda row: row['total_us'])[-max(1, math.ceil(len(rows) * .01)):]
        output.append(dict(name=run['name'], repetition=run['repetition'],
                           all=describe(rows), slowest_one_percent=describe(slow), slow_samples=slow))
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(args.directory), indent=2))
