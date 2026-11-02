"""Report native cadence from verified pixels, presentations and a producer receipt.

This reports a single observation, not paired performance acceptance or proof of
120 content FPS. Display reference qualification is separate from content validity.
"""
import argparse
import json
import math
from pathlib import Path
import statistics

from echo_latency import percentile
from native_display_reference import qualify_display
from terminal_bench_report import finite_number, latency_samples, validate_telar_display_sync


def analyze_content(result, producer):
    validate_telar_display_sync(result)
    if result.get('endpoint') != 'presented':
        raise ValueError('cadence requires a verified native presentation endpoint')
    # All initial input responses still require the original pixel/presentation oracle.
    latency_samples(result)
    cadence = result['cadence']
    if result['failed'] or cadence['overflow'] or not result['setup_complete']:
        raise ValueError('native setup failed or cadence buffer overflowed')
    start, end = cadence['window_start'], cadence['window_end']
    if not math.isfinite(start) or not math.isfinite(end) or start <= 0 or end <= start or not cadence['frames']:
        raise ValueError('missing cadence observation window')
    frames = sorted(cadence['frames'], key=lambda f: f['presented_at'])
    if any(f['verified'] is not True or not start <= f['presented_at'] < end for f in frames):
        raise ValueError('unverified pixels or missing/out-of-window native presentation')
    if len({f['drawable_id'] for f in frames}) != len(frames):
        raise ValueError('duplicate drawable observation')
    if (not producer['events'] or not finite_number(producer['rate_hz']) or producer['rate_hz'] <= 0
            or any(type(e['sequence']) is not int or e['sequence'] <= 0
                   or any(not finite_number(e[key]) or e[key] <= 0 for key in ('accepted_ns', 'scheduled_ns'))
                   for e in producer['events'])):
        raise ValueError('missing or invalid producer rate, sequences or timestamps')
    events = {e['sequence']: e for e in producer['events']}
    if len(events) != len(producer['events']):
        raise ValueError('duplicate producer sequence')
    if any(f['sequence'] not in events for f in frames):
        raise ValueError('presented sequence missing from producer receipt')
    if any(events[f['sequence']]['accepted_ns'] / 1e9 > f['presented_at'] for f in frames):
        raise ValueError('content presented before its producer write')
    if any(b['sequence'] < a['sequence'] or b['presented_at'] <= a['presented_at']
           for a, b in zip(frames, frames[1:])):
        raise ValueError('sequence or native presentation moved backwards')
    changed = [f for i, f in enumerate(frames) if i == 0 or f['sequence'] != frames[i - 1]['sequence']]
    if len(changed) < 2:
        raise ValueError('no sustained changing content')
    gaps = [(b['presented_at'] - a['presented_at']) * 1000 for a, b in zip(changed, changed[1:])]
    delivered = sorted(events.values(), key=lambda e: e['sequence'])
    if (delivered[0]['accepted_ns'] / 1e9 > start or delivered[-1]['accepted_ns'] / 1e9 < end
            or any(b['sequence'] != a['sequence'] + 1 or b['accepted_ns'] <= a['accepted_ns']
                   for a, b in zip(delivered, delivered[1:]))):
        raise ValueError('producer receipt does not cover the measurement window continuously')
    checkpoint_seconds = .5
    checkpoint_count = round((end - start) / checkpoint_seconds)
    if abs(checkpoint_count * checkpoint_seconds - (end - start)) > 1e-6:
        raise ValueError('measurement window does not have complete rate checkpoints')
    offered = [sum(start + i * checkpoint_seconds <= e['accepted_ns'] / 1e9 < start + (i + 1) * checkpoint_seconds
                   for e in delivered) for i in range(checkpoint_count)]
    expected = producer['rate_hz'] * checkpoint_seconds
    if expected <= 0 or any(abs(count / expected - 1) > .05 for count in offered):
        raise ValueError('producer missed the unchanged 5% offered-rate tolerance')
    # Report producer pacing independently. This first prototype does not infer
    # display refresh opportunities from the screen's advertised maximum.
    scheduled_lateness = [(e['accepted_ns'] - e['scheduled_ns']) / 1e6 for e in delivered]
    return dict(qualified_native_content=True, observation_seconds=end - start,
                presented=len(frames), changed=len(changed), repeated=len(frames) - len(changed),
                changed_per_second=(len(changed) - 1) / (changed[-1]['presented_at'] - changed[0]['presented_at']),
                gap_p50_ms=statistics.median(gaps), gap_p95_ms=percentile(gaps, .95),
                gap_p99_ms=percentile(gaps, .99), longest_gap_ms=max(gaps),
                producer_rate_hz=producer['rate_hz'], producer_accepted=len(delivered),
                producer_lateness_p99_ms=percentile(scheduled_lateness, .99),
                producer_lateness_max_ms=max(scheduled_lateness),
                producer_rate_qualified=True, producer_half_second_counts=offered,
                active_refresh_qualified=False,
                note='Diagnostic only. Active display cadence and broader flows remain open.')


def report(result, producer):
    try:
        summary = analyze_content(result, producer)
    except ValueError as error:
        return dict(qualified_native_content=False, active_refresh_qualified=False, error=str(error))

    try:
        summary.update(qualify_display(result))
    except ValueError as error:
        summary.update(display_reference_qualified=False, active_refresh_qualified=False,
                       missed_refresh_classification_qualified=False, display_reference_error=str(error))
    resources = result['cadence'].get('resources')
    if resources is not None:
        keys = ('start_at', 'end_at', 'user_cpu_seconds', 'system_cpu_seconds')
        valid = (resources['start_ok'] and resources['end_ok']
                 and all(math.isfinite(resources[key]) for key in keys)
                 and resources['end_at'] > resources['start_at'] > 0
                 and resources['user_cpu_seconds'] >= 0 and resources['system_cpu_seconds'] >= 0)
        summary['resource_interval_qualified'] = valid
        if valid:
            summary['resources'] = resources
        else:
            summary['resource_error'] = 'Missing or invalid explicit CPU observation interval'
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('result', type=Path)
    parser.add_argument('producer', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    summary = report(json.loads(args.result.read_text()), json.loads(args.producer.read_text()))
    encoded = json.dumps(summary, indent=2, allow_nan=False) + '\n'
    if args.output:
        args.output.write_text(encoded)
    print(encoded, end='')
    return 0 if summary.get('qualified_native_content') and summary.get('active_refresh_qualified') else 1


if __name__ == '__main__':
    raise SystemExit(main())

