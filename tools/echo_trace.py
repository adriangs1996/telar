#!/usr/bin/env python3
"""Summarize traces from echo_path's single-outstanding-key fixture, not arbitrary traffic."""
import argparse
import collections
import json
from pathlib import Path
import statistics

import echo_latency

CHAIN = ['host_read', 'client_input', 'client_send_start', 'runtime_read',
         'runtime_dispatch', 'input_forward', 'foreground_start', 'foreground_done',
         'input_observed', 'pty_write_queued', 'pty_write_start', 'pty_read',
         'output_dispatch', 'vt_queued', 'vt_start', 'vt_done', 'ingest_dispatch',
         'runtime_send_start', 'client_read', 'client_frame', 'compose_start',
         'host_flush_start', 'host_flush_done']
OPTIONAL = {'input_forward', 'foreground_start', 'foreground_done', 'input_observed',
            'pty_write_queued', 'vt_queued'}


def load_events(directory):
    events = []
    paths = list(directory.glob('*.echo.jsonl'))
    if len(paths) != 2:
        raise ValueError(f'expected client and runtime traces, found {len(paths)}')
    for path in paths:
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        if 'dropped' not in rows[-1] or rows[-1]['dropped']:
            raise ValueError('incomplete or overflowing trace')
        events.extend(dict(row, process=path.name) for row in rows if 'ns' in row)
    events.sort(key=lambda row: row['ns'])
    return events


def fixture_chains(directory, erase=False):
    events = load_events(directory)
    present = {row['event'] for row in events}
    chain = [tag for tag in CHAIN if tag in present or tag not in OPTIONAL]
    blocks = []
    block = []
    for event in events:
        if event['event'] == 'host_read':
            if block:
                blocks.append(block)
            block = []
        if block or event['event'] == 'host_read':
            block.append(event)
    chains = []
    # The fixture sends 20 warmup pairs, then alternating '~' and DEL.
    # Do not mix idle-separated echoes with their immediate erases.
    for block in blocks[40 + int(erase)::2]:
        selected = []
        for event in block:
            if event['event'] == chain[len(selected)]:
                selected.append(event)
                if len(selected) == len(chain):
                    break
        if len(selected) != len(chain):
            continue
        chains.append(selected)
    if not chains:
        raise ValueError('no complete fixture chains')
    return chains


def summarize(directory, erase=False):
    durations = collections.defaultdict(list)
    for selected in fixture_chains(directory, erase):
        for start, end in zip(selected, selected[1:]):
            durations[f"{start['event']} -> {end['event']}"].append((end['ns'] - start['ns']) / 1000)
        durations['internal_total'].append((selected[-1]['ns'] - selected[0]['ns']) / 1000)
    if not durations:
        raise ValueError('no complete fixture chains')
    return {key: dict(n=len(values), p50_us=statistics.median(values),
                      p95_us=echo_latency.percentile(values, .95), raw_us=values)
            for key, values in durations.items()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--erase', action='store_true')
    args = parser.parse_args()
    print(json.dumps(summarize(args.directory, args.erase), indent=2))
