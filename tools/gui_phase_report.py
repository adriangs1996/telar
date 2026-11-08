#!/usr/bin/env python3
"""Partition qualified native terminal diagnostics by drawable and frame identity.

Intervals are elapsed wall time, not CPU attribution. Instrumented observations
cannot accept an optimization or establish a universal Qt penalty. Quantiles
from different stages must not be added; per-input additive stages are checked.
"""
import argparse
import json
import math
from pathlib import Path
import statistics

from bench_stack import percentile
from tab_switch_report import stage_samples, validate_switch
from terminal_bench_report import finite_number, latency_samples, validate_telar_display_sync


NANOSECONDS = 1_000_000_000
PANE_FRAME_TAG = 0x82


def summary(values):
    return dict(n=len(values), mean_ms=statistics.mean(values), p50_ms=statistics.median(values),
                p95_ms=percentile(values, .95), p99_ms=percentile(values, .99), max_ms=max(values))


def native_stages(result):
    samples = result.get('switch_samples', result.get('submission_samples'))
    presented = latency_samples(result)
    validate_telar_display_sync(result)
    if (not isinstance(samples, list) or len(samples) != len(presented)
            or type(result.get('warmup')) is not int or not 0 <= result['warmup'] < len(samples)
            or any(not isinstance(result.get(name), list) or len(result[name]) != len(samples)
                   or any(not finite_number(value) or value < 0 for value in result[name])
                   for name in ('gpu_ms', 'gpu_work_ms'))):
        raise ValueError('Incomplete native submission observations')
    if 'switch_samples' in result:
        stage_samples(result)
    if (type(result.get('failed')) is not int or result['failed'] != 0
            or result.get('mode') != 'gui-cpp' or result.get('endpoint') != 'presented'):
        raise ValueError('Native probe failed or has an unsupported client/endpoint')
    for name in ('app_active_start', 'app_active_end', 'window_key_start', 'window_key_end'):
        observations = result.get(name)
        if (not isinstance(observations, list) or len(observations) != len(samples)
                or any(value is not True for value in observations)):
            raise ValueError('Native foreground did not qualify')
    names = ('input_to_commit', 'commit_to_gpu', 'gpu_execution', 'gpu_to_presentation')
    values = {name: [] for name in names}
    previous_presented = 0
    for index, sample in enumerate(samples):
        times = [sample.get(name) for name in ('input_at', 'commit_at', 'gpu_started_at', 'gpu_ended_at', 'presented_at')]
        if (sample.get('commit_count') != 1 or isinstance(sample.get('commit_count'), bool)
                or any(not finite_number(value) or value <= 0 for value in times)
                or times[0] <= previous_presented or any(end < begin for begin, end in zip(times, times[1:]))):
            raise ValueError('Missing, ambiguous or unordered drawable submission')
        previous_presented = times[-1]
        durations = [(end - begin) * 1000 for begin, end in zip(times, times[1:])]
        if (not math.isclose(durations[2], result['gpu_work_ms'][index], abs_tol=1e-6, rel_tol=0)
                or not math.isclose(sum(durations), result['presentation_ms'][index], abs_tol=1e-6, rel_tol=0)
                or not finite_number(sample.get('completed_at')) or sample['completed_at'] < times[3]
                or not math.isclose((sample['completed_at'] - times[0]) * 1000, result['gpu_ms'][index], abs_tol=1e-6, rel_tol=0)):
            raise ValueError('Native submission clocks disagree')
        if index >= result['warmup']:
            for name, duration in zip(names, durations):
                values[name].append(duration)
    values['input_to_presentation'] = presented[result['warmup']:]
    report = dict(samples=values, summary={name: summary(data) for name, data in values.items()})
    if any('encoder_started_at' in sample or 'encoder_count' in sample for sample in samples):
        report['encoding'] = encoder_stages(samples, result['warmup'])
    return report


def encoder_stages(samples, warmup):
    values = dict(input_to_encoder=[], encoder_to_commit=[])
    for index, sample in enumerate(samples):
        at = sample.get('encoder_started_at')
        if (not finite_number(at) or not sample['input_at'] <= at <= sample['commit_at']
                or type(sample.get('encoder_count')) is not int or sample['encoder_count'] != 1):
            raise ValueError('Missing, ambiguous or unordered drawable encoder')
        if index >= warmup:
            values['input_to_encoder'].append((at - sample['input_at']) * 1000)
            values['encoder_to_commit'].append((sample['commit_at'] - at) * 1000)
    return dict(scope='First qualified drawable encoder entry through commit, including observer readback work; not CPU attribution.',
                samples=values, summary={name: summary(data) for name, data in values.items()})


def load_trace(path, pid):
    rows = [json.loads(line) for line in Path(path).read_text().splitlines()]
    if not rows:
        raise ValueError('Missing GUI trace')
    header, *records = rows
    if (header.get('pid') != pid or header.get('clock') != 'CLOCK_UPTIME_RAW ns'
            or type(header.get('count')) is not int or header['count'] != len(records)
            or header.get('dropped') != 0 or type(header.get('capacity')) is not int
            or not 0 < header['count'] <= header['capacity']):
        raise ValueError('Incomplete, overflowing or wrong-process GUI trace')
    for record in records:
        if (not isinstance(record.get('name'), str) or any(type(record.get(name)) is not int or record[name] < 0
                for name in ('begin_ns', 'end_ns', 'thread', 'object', 'work', 'kind'))
                or record['begin_ns'] > record['end_ns'] or record['thread'] == 0):
            raise ValueError('Invalid GUI trace record')
    records.sort(key=lambda row: row['begin_ns'])
    clocks = [row for row in records if row['name'] == 'trace.clock']
    if len(clocks) != 2 or clocks[0]['end_ns'] >= clocks[1]['begin_ns']:
        raise ValueError('Missing GUI startup/shutdown clock brackets')
    if any(not row['begin_ns'] <= row['work'] <= row['end_ns'] for row in clocks):
        raise ValueError('GUI and native clocks do not share the qualified epoch')
    return records


def gui_stages(result, records, panes):
    native_stages(result)
    samples = result.get('switch_samples', result.get('submission_samples'))
    clocks = [row for row in records if row['name'] == 'trace.clock']
    if (len(clocks) != 2 or clocks[0]['end_ns'] > samples[0]['input_at'] * NANOSECONDS
            or clocks[1]['begin_ns'] < samples[-1]['presented_at'] * NANOSECONDS):
        raise ValueError('GUI clocks do not cover native observations')
    values = {}
    matches = []
    for index, sample in enumerate(samples):
        start = sample['input_at'] * NANOSECONDS
        commit = sample['commit_at'] * NANOSECONDS
        if 'switch_samples' in result:
            pane = panes[sample['observed_tab']]
        else:
            keys = {row['work'] for row in records if row['name'] == 'terminal.key' and start <= row['begin_ns'] <= commit}
            if len(keys) != 1 or 0 in keys:
                raise ValueError('Missing or ambiguous terminal input identity')
            pane = keys.pop()
        paints = [row for row in records if row['name'] == 'terminal.paint' and row['work'] == pane
                  and start <= row['begin_ns'] <= row['end_ns'] <= commit]
        if not paints:
            raise ValueError('No target-pane scene on the qualified drawable')
        paint = paints[-1]
        dispatched = [row for row in records if row['name'] == 'frame.dispatch' and row['work'] == pane
                      and row['kind'] == paint['kind'] and start <= row['begin_ns'] <= row['end_ns'] <= paint['begin_ns']]
        # Graphics messages can also return Change::terminal without advancing
        # frameId. Only a scope inside the actual PaneFrame payload is eligible.
        matched = [(dispatch, payload) for dispatch in dispatched for payload in records
                   if payload['name'] == 'socket.consume' and payload['work'] == PANE_FRAME_TAG
                   and start <= payload['begin_ns'] <= dispatch['begin_ns'] <= dispatch['end_ns'] <= payload['end_ns']]
        if len(matched) != 1:
            raise ValueError('Missing or ambiguous exact-frame dispatch and payload')
        dispatch, consumed = matched[0]
        before = [row for row in records if row['name'] == 'qt.before_sync'
                  and dispatch['end_ns'] <= row['begin_ns'] <= paint['begin_ns']]
        after = [row for row in records if row['name'] == 'qt.after_sync'
                 and paint['end_ns'] <= row['begin_ns'] <= commit]
        if not before or not after:
            raise ValueError('Missing target scene synchronization boundaries')
        before, after = before[-1], after[0]
        rendering = [row for row in records if row['name'] == 'qt.before_render'
                     and after['begin_ns'] <= row['begin_ns'] <= commit]
        rendered = [row for row in records if row['name'] == 'qt.after_render'
                    and after['begin_ns'] <= row['begin_ns'] <= commit]
        if len(rendering) != 1 or len(rendered) != 1:
            raise ValueError('Missing or ambiguous target rendering boundaries')
        points = [('input', start), ('payload_dispatch', consumed['begin_ns']),
                  ('decoded', dispatch['begin_ns']), ('subscribers_done', dispatch['end_ns']),
                  ('sync_begin', before['begin_ns']), ('paint_begin', paint['begin_ns']),
                  ('paint_end', paint['end_ns']), ('sync_end', after['begin_ns']),
                  ('render_begin', rendering[0]['begin_ns']), ('render_end', rendered[0]['begin_ns']), ('commit', commit)]
        if any(end < begin for (_, begin), (_, end) in zip(points, points[1:])):
            raise ValueError('Unordered target GUI stages')
        holds = sum(row['name'] == 'pacer.decision' and row['work'] == 1
                    and dispatch['end_ns'] <= row['begin_ns'] <= before['begin_ns'] for row in records)
        matches.append(dict(input_index=index, pane_id=pane, frame_id=paint['kind'], pacer_holds=holds))
        if index < result['warmup']:
            continue
        for (name, begin), (next_name, end) in zip(points, points[1:]):
            values.setdefault(name + '_to_' + next_name, []).append((end - begin) / 1e6)
    return dict(samples=values, summary={name: summary(data) for name, data in values.items()}, matches=matches)


def analyze_directory(directory, host_path, trace=None):
    directory = directory.resolve()
    host = json.loads(host_path.read_text())
    phases = {row.get('phase') for row in host.get('observations', []) if row.get('valid') is True}
    if (host.get('status') != 'qualified' or host.get('eligible') is not True
            or not {'before:' + directory.name, 'after:' + directory.name} <= phases):
        raise ValueError('No qualified host boundaries for this run')
    result = json.loads((directory / 'result.json').read_text())
    shutdown = json.loads((directory / 'shutdown.json').read_text())
    if shutdown.get('returncode') != 0 or any(shutdown.get(name) is not True
            for name in ('exited', 'children_exited', 'socket_removed', 'cleanup_complete')):
        raise ValueError('Owned runtime cleanup did not qualify')
    panes = {}
    if 'switch_samples' in result:
        receipts = [json.loads(path.read_text()) for path in sorted((directory / 'switching').glob('*.json'))]
        publications = {int(path.stem): path.read_bytes() for path in (directory / 'switching').glob('*.events')}
        workload = validate_switch(result, receipts, publications, require_phase=True)
        panes = {row['tab_index']: row['identities']['TELAR_PANE_ID'] for row in receipts}
    else:
        receipts = [json.loads(path.read_text()) for path in (directory / 'receipts').glob('*.json')]
        if (result.get('case') != 'single' or len(receipts) != 1 or receipts[0].get('role') != 'primary'
                or receipts[0].get('error') is not None or receipts[0].get('phase') not in ('ready', 'finished')):
            raise ValueError('Typing marker fixture did not qualify')
        final = receipts[0]['phase'] == 'finished'
        if final and receipts[0].get('marker_inputs') != len(latency_samples(result)):
            raise ValueError('Final typing receipt disagrees with native inputs')
        # The ordinary fixture can exit before publishing its final receipt.
        # Native acceptance verifies every alternating pixel; an initial receipt
        # is geometry evidence, never an independent final input-count oracle.
        workload = dict(interaction='single-pane typing', verified_native_markers=len(latency_samples(result)),
                        final_fixture_receipt=final, final_fixture_inputs=receipts[0]['marker_inputs'] if final else None)
    report = dict(scope=__doc__, workload=workload, native=native_stages(result))
    if trace:
        identity = json.loads((directory / 'gui-identity.json').read_text())
        records = load_trace(trace, identity['pid'])
        report['gui'] = gui_stages(result, records, panes)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--host-load', required=True, type=Path)
    parser.add_argument('--trace', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = analyze_directory(args.directory, args.host_load, args.trace)
    with args.output.open('x') as file:
        file.write(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
