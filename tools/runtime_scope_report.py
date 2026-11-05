"""Attribute diagnostic runtime scope elapsed time to qualified native phases.

Elapsed scope time includes waiting and observer overhead; it is not CPU time.
Only instrumented scopes are visible. Exclusive time excludes their direct
children, but still includes uninstrumented callees. Thread totals may overlap.
"""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import re

from runtime_phase_report import summarize as summarize_phases


def unsigned(value, name, positive=False):
    if type(value) is not int or not int(positive) <= value < 2**64:
        raise ValueError(f'Invalid unsigned field: {name}')
    return value


def validate_trace(header, records, pid):
    for key in ('pid', 'capacity', 'count', 'dropped'):
        unsigned(header[key], key, key in ('pid', 'capacity'))
    if header['pid'] != pid or header['clock'] != 'CLOCK_UPTIME_RAW ns':
        raise ValueError('Trace identity or clock mismatch')
    if header['dropped'] or header['count'] != len(records) or header['count'] > header['capacity']:
        raise ValueError('Incomplete or overflowing scope trace')
    if not records:
        raise ValueError('Empty scope trace')
    for record in records:
        if not isinstance(record['name'], str) or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.]*', record['name']):
            raise ValueError('Invalid scope name')
        for key in ('begin_ns', 'end_ns', 'thread', 'object', 'work', 'kind'):
            unsigned(record[key], key, key == 'thread')
        if record['end_ns'] < record['begin_ns']:
            raise ValueError('Reversed scope clock')


def children_by_record(records):
    children = [[] for _ in records]
    threads = defaultdict(list)
    for index, record in enumerate(records):
        threads[record['thread']].append(index)
    for indexes in threads.values():
        # Records are appended at scope exit. A parent with identical timestamps
        # therefore follows its child; visit that parent first.
        indexes.sort(key=lambda i: (records[i]['begin_ns'], -records[i]['end_ns'], -i))
        stack = []
        for index in indexes:
            record = records[index]
            if record['begin_ns'] == record['end_ns']:
                continue
            while stack and record['begin_ns'] >= records[stack[-1]]['end_ns']:
                stack.pop()
            if stack:
                if record['end_ns'] > records[stack[-1]]['end_ns']:
                    raise ValueError('Crossing scopes on one thread')
                children[stack[-1]].append(index)
            stack.append(index)
    return children


def attribute(records, windows):
    children = children_by_record(records)
    report = {}
    previous_end = 0
    for name, start, end in windows:
        unsigned(start, 'window start')
        unsigned(end, 'window end')
        if end <= start or start < previous_end or name in report:
            raise ValueError('Invalid phase windows')
        previous_end = end
        groups = {}
        def clipped(record):
            return max(0, min(end, record['end_ns']) - max(start, record['begin_ns']))
        for index, record in enumerate(records):
            inclusive = clipped(record)
            if inclusive == 0:
                continue
            key = (record['name'], record['kind'])
            group = groups.setdefault(key, dict(name=key[0], kind=key[1], overlapping_count=0,
                                                contained_count=0, boundary_crossing_count=0,
                                                contained_work=0, inclusive_elapsed_ns=0,
                                                exclusive_elapsed_ns=0))
            exclusive = inclusive - sum(clipped(records[child]) for child in children[index])
            if exclusive < 0:
                raise ValueError('Negative exclusive scope time')
            contained = start <= record['begin_ns'] and record['end_ns'] <= end
            group['overlapping_count'] += 1
            group['contained_count'] += int(contained)
            group['boundary_crossing_count'] += int(not contained)
            group['contained_work'] += record['work'] if contained else 0
            group['inclusive_elapsed_ns'] += inclusive
            group['exclusive_elapsed_ns'] += exclusive
        report[name] = dict(start_ns=start, end_ns=end,
                            groups=sorted(groups.values(), key=lambda g: (-g['exclusive_elapsed_ns'], g['name'], g['kind'])))
    return report


def summarize(outer, phase, result, header, records):
    counters = summarize_phases(outer, phase, result)
    validate_trace(header, records, outer['identity']['pid'])
    points = [outer['start'], *phase['snapshots'], outer['end']]
    names = ('setup', 'warmup', 'measured_inputs', 'after_measurement')
    windows = [(name, points[i]['after_ns'], points[i + 1]['before_ns']) for i, name in enumerate(names)]
    if not any(record['begin_ns'] <= windows[0][1] and record['end_ns'] >= windows[-1][2]
               and record['name'] == 'runtime.run' for record in records):
        raise ValueError('Runtime run scope does not cover the resource window')
    return dict(scope=__doc__, valid=True, trace=header, counters=counters,
                phases=attribute(records, windows))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    def read(name):
        return json.loads((args.directory / name).read_text())
    outer = read('runtime-resources.json')
    trace = args.directory / f"runtime-trace.{outer['identity']['pid']}.jsonl"
    with trace.open() as stream:
        header = json.loads(next(stream))
        records = [json.loads(line) for line in stream]
    report = summarize(outer, read('runtime-phase.json'), read('result.json'), header, records)
    with args.output.open('x') as output:
        output.write(json.dumps(report, indent=2) + '\n')
    print(f"Validated {len(records)} scope records for runtime {header['pid']}")


if __name__ == '__main__':
    main()
