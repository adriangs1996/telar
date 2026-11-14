#!/usr/bin/env python3
"""Alternate two builds of the runtime under runtime-probe: PTY output to client frames.

Each sample starts an isolated telar-runtime of one build, and that build's runtime-probe opens
a pane whose child prints one synchronized screen of the workload each time the probe asks; the
probe waits for the frame that shows it. The sample is the probe's own timer around that loop,
in ns per frame. The probe's dump (screens, text, matches, resize and reconnect) must be the
same bytes for both builds.

With --count, each sample instead runs the runtime under /usr/bin/time -l twice, serving the
probe with the sample's frames and with two warmup frames, and reports the difference of the
runtime's retired instructions and elapsed cycles per frame: start-up, the probe's fixed
requests and shutdown cancel out.

Build each variant in its own Release directory with

    tools/cpp configure runtime -B <dir> --config Release
    tools/cpp build runtime -B <dir> -- --target telar-runtime runtime-probe

and pass the two directories. The host gate of tools/benchmark_host.py discards the whole
series when another build runs or the load is too high, so start it on a quiet host.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'tools'))
from benchmark_host import HostLoadGate

# The workloads of runtime_probe.cpp's fixture with a deterministic dump.
CASES = ('sparse', 'full', 'unicode', 'bulk', 'scroll', 'graphemes', 'modes', 'links', 'mixed', 'graphics-cursor', 'colors')
WARMUP_FRAMES = 2
COUNTERS = {'instructions': re.compile(r'^\s*(\d+)\s+instructions retired\s*$', re.M),
            'cycles': re.compile(r'^\s*(\d+)\s+cycles elapsed\s*$', re.M)}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def environment_in(root):
    environment = {key: value for key, value in os.environ.items() if not key.startswith(('TELAR_', 'XDG_'))}

    for key in ('HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR'):
        location = root / key.lower()
        location.mkdir()
        environment[key] = str(location)

    environment['TERM'] = 'xterm-256color'
    return environment


def stop(server, runtime_pid):
    if server.poll() is None:
        try:
            os.kill(runtime_pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

    try:
        return server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait()
        raise RuntimeError('The runtime did not stop on SIGTERM')


def runtime_child(server):
    """The runtime's pid when /usr/bin/time runs it, else the server's own."""
    deadline = time.monotonic() + 5

    while True:
        children = subprocess.run(['pgrep', '-P', str(server.pid)], capture_output=True, text=True).stdout.split()
        if children:
            return int(children[0])

        if server.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('The runtime did not start under /usr/bin/time')

        time.sleep(0.005)


def serve(directory, case, frames, counted=False):
    """One isolated runtime of the build in `directory` serving runtime-probe; the probe's report,
    the dump's digest and, when counted, the runtime's counters."""
    # The socket path must fit sun_path, which a deep temporary directory may not.
    with tempfile.TemporaryDirectory(prefix='telar-runtime-probe-', dir='/tmp') as temporary:
        root = Path(temporary)
        endpoint = root / 'runtime.sock'
        dump = root / 'dump.bin'
        environment = environment_in(root)
        command = [str(directory / 'telar-runtime'), '--socket', str(endpoint), '--history', ':memory:', '--no-session', '--no-resume', '--no-config']
        if counted:
            command = ['/usr/bin/time', '-l', *command]

        with (root / 'runtime.log').open('w+') as log:
            server = subprocess.Popen(command, env=environment, cwd=root, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            runtime_pid = runtime_child(server) if counted else server.pid

            try:
                deadline = time.monotonic() + 15
                while not endpoint.exists():
                    if server.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('The runtime failed to start')

                    time.sleep(0.01)

                result = subprocess.run([str(directory / 'runtime-probe'), str(endpoint), case, str(frames), str(dump)],
                                        env=environment, capture_output=True, text=True, timeout=300)
                if result.returncode:
                    raise RuntimeError(f'runtime-probe {case} failed ({result.returncode}): {result.stderr.strip()}')

                report = json.loads(result.stdout)
            finally:
                code = stop(server, runtime_pid)
                log.seek(0)
                output = log.read()

            if code not in (0, -signal.SIGTERM, 128 + signal.SIGTERM):
                raise RuntimeError(f'The runtime exited with {code}: {output}')

            counters = {}
            if counted:
                for name, pattern in COUNTERS.items():
                    match = pattern.search(output)
                    if not match:
                        raise RuntimeError(f'/usr/bin/time -l reported no {name}: {output}')

                    counters[name] = int(match.group(1))

            return report, digest(dump), counters


def frames_for(directories, case, target_ns, maximum):
    # The slower variant sets the count, so both samples take at least the target.
    per_frame = max(serve(directory, case, 50)[0]['ns_per_iteration'] for directory in directories.values())
    return max(50, min(maximum, int(target_ns / max(per_frame, 1))))


def timed(directory, case, frames):
    report, dump, _ = serve(directory, case, frames)
    return report['ns_per_iteration'], dump


def counted(directory, case, frames):
    long, dump, measured = serve(directory, case, frames, counted=True)
    _, _, warmup = serve(directory, case, WARMUP_FRAMES, counted=True)
    per_frame = {name: (measured[name] - warmup[name]) / (frames - WARMUP_FRAMES) for name in COUNTERS}

    return per_frame, dump


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--baseline', type=Path, required=True, help='Release build directory of the baseline')
    parser.add_argument('--candidate', type=Path, required=True, help='Release build directory of the candidate')
    parser.add_argument('--output', type=Path, required=True, help='new directory for the report and the host gate')
    parser.add_argument('--case', action='append', choices=CASES, help='workload to run; repeat it for several, all by default')
    parser.add_argument('--pairs', type=int, default=7)
    parser.add_argument('--sample-ms', type=float, default=200, help='target duration of each timed sample')
    parser.add_argument('--max-frames', type=int, default=20000)
    parser.add_argument('--count', action='store_true', help='count instructions and cycles per frame instead of timing')
    options = parser.parse_args()
    if not 1 <= options.pairs <= 31 or not options.sample_ms > 0 or options.max_frames < 50:
        parser.error('Expected 1..31 pairs, a positive sample duration and at least 50 frames')

    if options.count and platform.system() != 'Darwin':
        parser.error('--count reads the counters of macOS /usr/bin/time -l')

    directories = {name: getattr(options, name).resolve() for name in ('baseline', 'candidate')}
    for name, directory in directories.items():
        for binary in ('telar-runtime', 'runtime-probe'):
            if not (directory / binary).is_file():
                parser.error(f'No {binary} in the {name} directory; build it with --target {binary}')

    binaries = {name: {binary: str(directory / binary) for binary in ('telar-runtime', 'runtime-probe')} for name, directory in directories.items()}
    digests = {name: {binary: digest(Path(path)) for binary, path in paths.items()} for name, paths in binaries.items()}
    output = options.output.resolve()

    output.mkdir(parents=True, exist_ok=False)
    host = HostLoadGate(output / 'host-load.json')
    host.checkpoint('before-series')
    manifest = dict(binaries=binaries, sha256=digests, command_line=sys.argv, mode='count' if options.count else 'time',
                    uptime=subprocess.check_output(['uptime'], text=True).strip())
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    results = {}

    for case in options.case or CASES:
        frames = frames_for(directories, case, options.sample_ms * 1e6, options.max_frames)

        # Warm the page cache and the first allocations of both variants.
        for directory in directories.values():
            timed(directory, case, frames)

        pairs = []
        dumps = set()

        for index in range(options.pairs):
            order = ['baseline', 'candidate'] if index % 2 == 0 else ['candidate', 'baseline']
            pair = {}

            for name in order:
                with host.run(f'{case}-{index}-{name}'):
                    pair[name], dump = (counted if options.count else timed)(directories[name], case, frames)

                dumps.add(dump)

            pairs.append(pair)

        # The oracle: both builds show the probe the same screens.
        if len(dumps) != 1:
            raise ValueError(f'{case}: the dumps differ between runs: {sorted(dumps)}')

        result = dict(frames=frames, pairs=pairs, dump_sha256=dumps.pop())
        metrics = COUNTERS if options.count else ('ns',)

        for metric in metrics:
            value = (lambda pair, name: pair[name][metric]) if options.count else (lambda pair, name: pair[name])
            ratios = [value(pair, 'candidate') / value(pair, 'baseline') for pair in pairs]
            if not all(math.isfinite(ratio) and ratio > 0 for ratio in ratios):
                raise ValueError(f'{case}: expected positive finite {metric}')

            wins = sum(ratio < 1 for ratio in ratios)
            result[metric] = dict(baseline_median=statistics.median(value(pair, 'baseline') for pair in pairs),
                                  candidate_median=statistics.median(value(pair, 'candidate') for pair in pairs),
                                  baseline_range=[min(value(pair, 'baseline') for pair in pairs), max(value(pair, 'baseline') for pair in pairs)],
                                  candidate_range=[min(value(pair, 'candidate') for pair in pairs), max(value(pair, 'candidate') for pair in pairs)],
                                  median_paired_ratio=statistics.median(ratios), candidate_wins=wins)
            print(f"{case:16} {metric:12} {result[metric]['baseline_median']:14.1f} -> {result[metric]['candidate_median']:14.1f} per frame  "
                  f"ratio {result[metric]['median_paired_ratio']:.4f}  wins {wins}/{options.pairs}", flush=True)

        results[case] = result

    host.finish()
    for name, paths in binaries.items():
        for binary, path in paths.items():
            if digest(Path(path)) != digests[name][binary]:
                raise ValueError(f'The {name} {binary} changed during the comparison')

    report = dict(manifest=manifest, results=results,
                  acceptance='The target case wins at least 6 of 7 pairs and no workload loses consistently '
                             '(0-1 wins) unless the loss is proven to be code placement.')

    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
