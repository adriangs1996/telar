"""Darwin runtime counters outside the native GUI input/presentation interval.

Compile macos_process_resources.c separately and pass its executable to capture.
The harness adapter is serial: it temporarily wraps its runtime identity/cleanup
functions. CPU covers GUI startup, warmup and measurement, not only input samples.
"""

from contextlib import contextmanager
import json
from pathlib import Path
import re
import subprocess


def validate_snapshot(result):
    if not isinstance(result, dict):
        raise ValueError('Invalid resource snapshot')
    counters = ('pid', 'before_ns', 'after_ns', 'timebase_numer', 'timebase_denom',
                'start_abstime', 'exit_abstime', 'user_ticks', 'system_ticks',
                'idle_wakeups', 'interrupt_wakeups', 'pageins', 'resident_bytes',
                'footprint_bytes', 'lifetime_max_footprint_bytes')
    if any(type(result.get(key)) is not int or not 0 <= result[key] <= 2**64 - 1 for key in counters):
        raise ValueError('Invalid resource counter representation')
    if not isinstance(result.get('uuid'), str) or not re.fullmatch('[0-9a-f]{32}', result['uuid']):
        raise ValueError('Invalid executable UUID')
    if not 0 < result['pid'] <= 2**31 - 1 or result['start_abstime'] == 0 or result['exit_abstime'] != 0:
        raise ValueError('Invalid live process resource identity')
    if result['before_ns'] > result['after_ns'] or not all(0 < result[key] <= 2**32 - 1 for key in ('timebase_numer', 'timebase_denom')):
        raise ValueError('Invalid resource clock')


def snapshot(helper, pid):
    result = json.loads(subprocess.check_output([str(helper), str(pid)], text=True, timeout=5))
    validate_snapshot(result)
    if result['pid'] != pid:
        raise ValueError('Resource helper returned another process')
    return result


def interval(start, end):
    validate_snapshot(start)
    validate_snapshot(end)
    for key in ('pid', 'start_abstime', 'uuid', 'timebase_numer', 'timebase_denom'):
        if start[key] != end[key]:
            raise ValueError(f'Resource identity/clock mismatch: {key}')
    if not start['before_ns'] <= start['after_ns'] <= end['before_ns'] <= end['after_ns']:
        raise ValueError('Resource clock is not monotonic')
    counts = ('user_ticks', 'system_ticks', 'idle_wakeups', 'interrupt_wakeups', 'pageins')
    if any(start[k] < 0 or end[k] < start[k] for k in counts):
        raise ValueError('Resource counter regressed')
    scale = start['timebase_numer'] / start['timebase_denom'] / 1e9
    return dict(valid=True, user_cpu_seconds=(end['user_ticks'] - start['user_ticks']) * scale,
                system_cpu_seconds=(end['system_ticks'] - start['system_ticks']) * scale,
                minimum_wall_seconds=(end['before_ns'] - start['after_ns']) / 1e9,
                maximum_wall_seconds=(end['after_ns'] - start['before_ns']) / 1e9,
                idle_wakeups=end['idle_wakeups'] - start['idle_wakeups'],
                interrupt_wakeups=end['interrupt_wakeups'] - start['interrupt_wakeups'],
                pageins=end['pageins'] - start['pageins'])


@contextmanager
def capture(harness, path, helper):
    path = Path(path)
    if path.exists():
        raise FileExistsError(path)
    old_identity, old_stop = harness.runtime_identity, harness.stop_runtime
    state = dict(scope='Runtime-only counters sampled before GUI launch and after GUI process exit. Includes GUI setup, warmup, measured inputs and boundary-observer time; excludes runtime startup, shutdown and child CPU. Memory is two snapshots and a lifetime footprint maximum, not an interval peak. No observer runs inside the GUI input/presentation phase.', errors=[])

    def identify(socket, executable):
        identity = old_identity(socket, executable)
        state['identity'] = identity
        state['start'] = snapshot(helper, identity['pid'])
        return identity

    def stop(binary, env):
        try:
            if 'identity' in state:
                actual = harness.process_identity(state['identity']['pid'])
                if any(actual[key] != state['identity'][key] for key in ('pid', 'path', 'sha256')):
                    raise ValueError('Runtime identity changed before final resource capture')
                state['end'] = snapshot(helper, actual['pid'])
        except Exception as error:
            state['errors'].append(repr(error))
        finally:
            result = old_stop(binary, env)
            state['cleanup'] = result
        return result

    harness.runtime_identity, harness.stop_runtime = identify, stop
    try:
        yield state
        if state['errors']:
            raise ValueError(state['errors'])
        state['interval'] = interval(state['start'], state['end'])
    finally:
        harness.runtime_identity, harness.stop_runtime = old_identity, old_stop
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(state, indent=2) + '\n')
