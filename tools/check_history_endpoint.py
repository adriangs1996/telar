#!/usr/bin/env python3
"""Check final-reply ordering for a native history template.

Consumes a --trace-history --diagnostic run and before/after clock brackets.
This qualifies an endpoint for reply-dependent workloads, never performance.
Legitimate prefix rendering or cached results may fail this narrower contract.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'services/gui-cpp/tools'))
from history_capture_proxy import history_results_tag

MAXIMUM_CLOCK_UNCERTAINTY_SECONDS = 1e-6


def load(path):
    return json.loads(path.read_text())


def require(condition, message):
    if not condition:
        raise ValueError(message)


def clock_interval(calibration):
    brackets = []
    for boundary in ('before', 'after'):
        readings = calibration[boundary]
        require(bool(readings), 'Missing clock boundary readings')
        for reading in readings:
            before = reading['monotonic_before_ns'] / 1e9
            after = reading['monotonic_after_ns'] / 1e9
            native = reading['ca_seconds']
            require(all(math.isfinite(x) and x > 0 for x in (before, after, native)), 'Invalid clock')
            require(before <= after, 'Reversed clock bracket')
            brackets.append((before - native, after - native))
    low = max(x[0] for x in brackets)
    high = min(x[1] for x in brackets)
    require(low <= high and high - low <= MAXIMUM_CLOCK_UNCERTAINTY_SECONDS, 'Clock alignment is inconsistent or exceeds 1 us')
    return low, high


def check(directory, calibration_path):
    paths = {
        'result': directory / 'result.json',
        'trace': directory / 'history-trace.json',
        'frames': directory / 'client/observations.json.frames/timeline.json',
        'host': directory / 'host-load.json',
        'cleanup': directory / 'client/cleanup.json',
        'clocks': calibration_path,
    }
    data = {name: load(path) for name, path in paths.items()}
    result, trace = data['result'], data['trace']
    require(result['passed'] and result['pending_submissions'] == 0, 'Native run did not qualify')
    require(result['zero_new_result_frames'] == 0 and result['dropped_count'] == 0 and result['display_sync'], 'Native presentation guards did not qualify')
    require(result.get('query_offered_rate_qualified', True) and result.get('burst_offered_rate_qualified', True), 'Offered rate did not qualify')
    require(data['host']['eligible'], 'Host load did not qualify')
    require(all(data['cleanup'][key] for key in ('cleanup_complete', 'children_exited', 'exited')), 'Incomplete cleanup')
    require(not trace['errors'], 'Relay errors')
    low, high = clock_interval(data['clocks'])
    offset = (low + high) / 2
    frames = {frame['drawable_id']: frame for frame in data['frames']}
    require(len(frames) == len(data['frames']), 'Duplicate drawable records')
    replies = {(row['connection'], row['identity']): row for row in trace['responses']}
    require(len(replies) == len(trace['responses']), 'Duplicate replies')
    trials, rows, used = result['trials'], [], set()
    require(bool(trials), 'No trials')
    for index, trial in enumerate(trials):
        end = trials[index + 1]['query_start_time'] if index + 1 < len(trials) else math.inf
        requests = [row for row in trace['queries'] if row['query'] == trial['query'] and
                    trial['input_time'] <= row['received_ns'] / 1e9 - offset < end]
        require(len(requests) == 1, f'Trial {index}: final request is absent or ambiguous')
        request = requests[0]
        key = (request['connection'], request['identity'])
        require(key not in used and key in replies, f'Trial {index}: missing or reused reply')
        used.add(key)
        reply, frame = replies[key], frames[trial['drawable_id']]
        require(reply['tag'] == history_results_tag, f'Trial {index}: query failed instead of returning results')
        require(request['received_ns'] <= reply['received_ns'] <= reply['forwarded_ns'], f'Trial {index}: invalid relay ordering')
        require(frame['matched'] == trial['query'] and frame['presented_time'] == trial['presented_time'], f'Trial {index}: drawable endpoint mismatch')
        times = [trial['input_time'], frame['committed_time'], frame['completed_time'], frame['presented_time'], reply['forwarded_ns'] / 1e9]
        require(all(math.isfinite(x) and x > 0 for x in times), f'Trial {index}: invalid timestamp')
        require(frame['committed_time'] >= trial['input_time'] and frame['completed_time'] >= frame['committed_time'], f'Trial {index}: invalid submission ordering')
        require(frame['presented_time'] >= frame['committed_time'], f'Trial {index}: presentation precedes submission')
        latest_reply = reply['forwarded_ns'] / 1e9 - low
        rows.append(dict(trial=index, query=trial['query'], request_id=request['identity'],
                         drawable_id=trial['drawable_id'],
                         reply_to_commit_lower_ms=(frame['committed_time'] - latest_reply) * 1000,
                         reply_to_present_lower_ms=(frame['presented_time'] - latest_reply) * 1000))
    qualified = all(row['reply_to_commit_lower_ms'] >= 0 and row['reply_to_present_lower_ms'] >= 0 for row in rows)
    return dict(reply_dependent_endpoint_qualified=qualified, performance_eligible=False,
                scope='Final-query reply precedes first matching drawable submission and presentation. Ordering alone does not prove causation, ranking, full visual parity or observer perturbation.',
                clock_offset_interval_seconds=[low, high], trials=rows,
                sources={name: dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest()) for name, path in paths.items()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--clock-calibration', type=Path, help='Defaults to RUN/clock-calibration.json')
    args = parser.parse_args()
    try:
        calibration = args.clock_calibration or args.run / 'clock-calibration.json'
        report = check(args.run.resolve(), calibration.resolve())
    except (OSError, KeyError, TypeError, ValueError) as error:
        parser.exit(1, f'Endpoint qualification failed: {error}\n')
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report['reply_dependent_endpoint_qualified'] else 1)


if __name__ == '__main__':
    main()
