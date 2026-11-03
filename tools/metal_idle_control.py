#!/usr/bin/env python3
"""Diagnose Metal callbacks after idle without Telar or Qt; never accept latency."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys

from benchmark_host import HostLoadGate
from bench_stack import process_identity


def analyze(text, readback):
    events = {name: {} for name in ('acquire', 'gpu', 'present', 'request')}
    setup = finish = None
    for line in text.splitlines():
        name, _, body = line.partition(' ')
        if name not in (*events, 'setup', 'finish'):
            continue
        fields = dict(token.split('=', 1) for token in body.split())
        if name == 'setup':
            if setup is not None:
                raise ValueError('Duplicate setup')
            setup = fields
        elif name == 'finish':
            if finish is not None:
                raise ValueError('Duplicate finish')
            finish = fields
        else:
            index = int(fields['index'])
            if index in events[name]:
                raise ValueError(f'Duplicate {name} for {index}')
            events[name][index] = fields

    def require(condition, message):
        if not condition:
            raise ValueError(message)

    def clock(event, key):
        value = float(event[key])
        require(math.isfinite(value) and value >= 0, f'Invalid {key}')
        return value

    require(setup is not None and finish is not None, 'Missing setup/finish')
    require(setup['mode'] in ('scheduled', 'command'), 'Unknown presentation mode')
    require(int(setup['readback']) == int(readback), 'Readback policy mismatch')
    require(int(setup['framebuffer_only']) == int(not readback), 'Framebuffer policy mismatch')
    require(all(int(finish[key]) == 42 for key in ('submitted', 'completed', 'callbacks')), 'Incomplete run')
    for name in ('acquire', 'gpu', 'present'):
        require(set(events[name]) == set(range(42)), f'Incomplete {name} events')
    require(set(events['request']) == (set(range(42)) if setup['mode'] == 'scheduled' else set()), 'Request path mismatch')
    scale = float(setup['scale'])
    require(math.isfinite(scale) and scale > 0, 'Invalid scale')
    expected_size = f'{int(800 * scale)}x{int(500 * scale)}'
    frames = []
    for index in range(42):
        acquire, gpu, present = [events[name][index] for name in ('acquire', 'gpu', 'present')]
        phase = 'warmup' if index < 20 else 'idle' if index < 22 else 'resume'
        require(acquire['phase'] == phase, 'Unexpected phase')
        require(int(acquire['changed']) == int(phase != 'idle'), 'Unexpected content change')
        require(acquire['drawable'] == gpu['drawable'] == present['drawable'], 'Drawable identity mismatch')
        require(int(acquire['drawable']) == index, 'Unexpected drawable sequence')
        require(acquire['size'] == expected_size, 'Unexpected scene size')
        require(acquire['pool'] == '3' and acquire['transaction'] == '0' and acquire['sync'] == '1', 'Layer policy mismatch')
        for event in (acquire, present):
            require(all(event[key] == '1' for key in ('active', 'key', 'visible')), 'Foreground not qualified')
        require(int(gpu['verified']) == (1 if readback else -1), 'GPU content verification mismatch')
        began, completed = clock(acquire, 'time'), clock(gpu, 'time')
        timestamp, callback = clock(present, 'timestamp'), clock(present, 'callback')
        require(began > 0 and completed >= began and callback >= began, 'Invalid clock ordering')
        require(timestamp == 0 or began <= timestamp <= callback, 'Invalid positive presentation time')
        if setup['mode'] == 'scheduled':
            request = events['request'][index]
            require(request['drawable'] == acquire['drawable'], 'Request identity mismatch')
            require(began <= clock(request, 'time') <= callback, 'Request ordering mismatch')
        frames.append(dict(index=index, phase=phase, began=began, gpu=completed,
                           presented=timestamp, callback=callback, content_verified=readback))
    for index in range(1, len(frames)):
        require(frames[index]['began'] - frames[index - 1]['began'] >= .05, 'Coalesced frame submissions')
    idle = frames[22]['began'] - frames[19]['began']
    isolation = frames[23]['began'] - frames[22]['began']
    require(idle >= 5 and isolation >= 2, 'Idle/isolation interval too short')
    require(frames[22]['callback'] < frames[23]['began'], 'First resume callback overlaps next submission')
    return dict(diagnostic_valid=True, performance_eligible=False, mode=setup['mode'],
                content_verified=readback, setup=setup, idle_seconds=idle,
                first_resume_isolation_seconds=isolation, first_resume=frames[22],
                zero_indices=[frame['index'] for frame in frames if frame['presented'] == 0],
                limitations='Boundary foreground observations; solid clears differ from Qt/Telar rendering. No physical scanout observation, timeout incidence estimate or performance comparison.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--presentation', choices=('scheduled', 'command', 'both'), default='both')
    parser.add_argument('--no-readback', action='store_true')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Requires macOS with Metal and an interactive desktop')
    output = args.output.resolve()
    output.mkdir(mode=0o700, exist_ok=False)
    source = Path(__file__).with_suffix('.m')
    binary = output / 'control'
    copies = [source, Path(__file__), source.with_name('benchmark_host.py'), source.with_name('bench_stack.py')]
    for path in copies:
        (output / path.name).write_bytes(path.read_bytes())
    with (output / 'build.log').open('w') as log:
        subprocess.run(['clang', '-O2', '-fobjc-arc', '-framework', 'AppKit', '-framework', 'QuartzCore',
                        '-framework', 'Metal', str(source), '-o', str(binary)], stdout=log, stderr=log, check=True, timeout=120)
    modes = ['scheduled', 'command'] if args.presentation == 'both' else [args.presentation]
    manifest = dict(scope=__doc__, policies=modes, readback=not args.no_readback,
                    warmup_frames=20, resume_frames=20, idle_seconds=5,
                    identical_idle_redraws_seconds=[2, 4], first_resume_isolation_seconds=2,
                    scheduling='Recursive 60ms delay after each submitted frame',
                    sha256={path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in [*copies, binary]},
                    uptime=subprocess.check_output(['uptime'], text=True))
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    host = HostLoadGate(output / 'host-load.json')
    host.checkpoint('before-series')
    receipts, results = [], []
    try:
        for mode in modes:
            with host.run(mode):
                log_path = output / f'{mode}.log'
                with log_path.open('w') as log:
                    child = subprocess.Popen([str(binary), mode, 'no-readback' if args.no_readback else 'readback'], stdout=log, stderr=log)
                    identity = None
                    try:
                        identity = process_identity(child.pid)
                        if identity['path'] != str(binary.resolve()):
                            raise ValueError(f'Unexpected child identity: {identity}')
                        status = child.wait(timeout=22)
                        if status:
                            raise RuntimeError(f'{mode} exited {status}: {log_path}')
                    finally:
                        # Popen owns this unreaped child; verify the executable before signaling it.
                        if child.poll() is None:
                            if process_identity(child.pid)['path'] != str(binary.resolve()):
                                raise ValueError('Refusing to signal an unexpected executable')
                            child.terminate()
                            try:
                                child.wait(timeout=3)
                            except subprocess.TimeoutExpired:
                                if process_identity(child.pid)['path'] != str(binary.resolve()):
                                    raise ValueError('Child executable changed before kill')
                                child.kill()
                                child.wait(timeout=3)
                        receipts.append(dict(mode=mode, identity=identity, returncode=child.returncode, exited=child.poll() is not None))
                        (output / 'owned-processes.json').write_text(json.dumps(receipts, indent=2) + '\n')
                results.append(analyze(log_path.read_text(), not args.no_readback))
        host.finish()
    except Exception as error:
        (output / 'result.json').write_text(json.dumps(dict(diagnostic_valid=False, performance_eligible=False, error=str(error)), indent=2) + '\n')
        raise
    report = dict(diagnostic_valid=True, performance_eligible=False, runs=results)
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
