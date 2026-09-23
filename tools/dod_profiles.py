#!/usr/bin/env python3
"""Extract documented exported table columns; preserve event names and denominators."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import xml.etree.ElementTree as ET


def table(path):
    root = ET.parse(path)
    ids = {node.get('id'): node for node in root.iter() if node.get('id')}
    def resolve(node):
        return ids[node.get('ref')] if node.get('ref') else node
    return root, resolve


def pmu_mode(directory):
    root, resolve = table(directory/'MetricTable.xml')
    totals = defaultdict(float)
    weighted = defaultdict(float)
    durations = defaultdict(float)
    intervals = set()
    rows = 0
    for row in root.findall('.//row'):
        fields = [resolve(child) for child in row]
        if not fields[5].get('fmt','').startswith('telar-dod-probe '):
            continue
        rows += 1
        name, value, duration = fields[3].text, float(fields[6].text), int(fields[1].text)
        intervals.add((fields[0].text, fields[4].get('id'), fields[7].text))
        if fields[8].text == '1':
            weighted[name] += value*duration
            durations[name] += duration
        else:
            totals[name] += value
    result = dict(intervals=len(intervals), rows=rows, exported_sums=dict(totals),
                  duration_weighted_fractions={name:weighted[name]/durations[name] for name in weighted},
                  scope='Whole CPU probe, including setup, warmup, all cases and teardown.')
    path = directory/'SamplingModeSamples.xml'
    if path.exists():
        root, resolve = table(path)
        leaves = defaultdict(lambda: defaultdict(int))
        pcs = defaultdict(lambda: defaultdict(int))
        cores = defaultdict(int)
        for row in root.findall('.//row'):
            fields = [resolve(child) for child in row]
            if not fields[3].get('fmt','').startswith('telar-dod-probe '):
                continue
            event = fields[1].text
            frames = [resolve(frame) for frame in fields[5]]
            if frames:
                leaves[event][frames[0].get('name','unknown')] += 1
            pcs[event][hex(int(fields[6].text))] += 1
            cores[fields[4].get('fmt','unknown')] += 1
        result['retired_instruction_samples'] = {event:dict(samples=sum(values.values()),
            leaf_samples=dict(sorted(values.items(),key=lambda item:-item[1])[:15]),
            pc_samples=dict(sorted(pcs[event].items(),key=lambda item:-item[1])[:10])) for event,values in leaves.items()}
        result['core_samples'] = dict(cores)
        result['sample_limit'] = 'Samples are not the exported event totals. No total load denominator, cache hit ratio, or DRAM byte estimate is available.'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    root, resolve = table(args.directory/'CPU Counters-MetricTable.xml')
    intervals = defaultdict(dict)
    for row in root.findall('.//row'):
        timestamp, duration, event, name, thread, process, value, core, ratio, _ = [resolve(child) for child in row]
        if not process.get('fmt','').startswith('telar-dod-probe '):
            continue
        key = (timestamp.text, duration.text, thread.get('id'), core.text)
        intervals[key][name.text] = float(value.text)
    cycles = sum(row['Cycles'] for row in intervals.values())
    categories = {name: sum(row.get(name, 0)*row['Cycles'] for row in intervals.values())/cycles
                  for name in ('Instruction Delivery Bottleneck','Discarded Bottleneck','Instruction Processing Bottleneck','Useful')}
    pmu = dict(mode='bottlenecks', intervals=len(intervals), counted_cycles=cycles,
               cycle_weighted_fractions=categories, raw_events=sorted({key for row in intervals.values() for key in row}),
               scope='Whole CPU probe process, including setup, warmup, all workloads and teardown.',
               limitation='This mode did not export L1D/LLC misses, instructions or bytes read from DRAM. No cache miss rate or IPC is derived.')
    root, resolve = table(args.directory/'Time Profiler-time-profile.xml')
    self_time = defaultdict(int)
    parents = defaultdict(int)
    rows = 0
    for row in root.findall('.//row'):
        fields = [resolve(child) for child in row]
        if len(fields) != 7 or fields[2].get('fmt','').split(' (')[0] != 'telar-dod-probe' or fields[4].get('fmt') != 'Running':
            continue
        weight = int(fields[5].text)
        frames = [resolve(frame) for frame in fields[6]]
        if not frames:
            continue
        rows += 1
        top = frames[0].get('name', frames[0].get('addr', 'unknown'))
        self_time[top] += weight
        # First probe workload ancestor separates workload families, not individual cases.
        workload = next((frame.get('name','') for frame in frames if frame.get('name','').startswith('ProfilingProbe.')), 'setup/dependency/other')
        parents[workload] += weight
    cpu = dict(running_samples=rows, sampled_weight_ns=sum(self_time.values()),
               leaf_weight_ns=dict(sorted(self_time.items(),key=lambda item:-item[1])[:40]),
               workload_ancestor_weight_ns=dict(sorted(parents.items(),key=lambda item:-item[1])),
               limitation='Sample weights, not measured calls or an application-wide ranking. Includes initialization and warmup.')
    result = dict(pmu=pmu, cpu=cpu)
    for mode in ('processing','l1d_miss_sampling'):
        directory = args.directory.parent/'pmu'/mode
        if directory.exists():
            result[mode] = pmu_mode(directory)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(pmu=pmu,cpu=cpu),indent=2))


if __name__ == '__main__':
    main()
