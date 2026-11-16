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

With --control, a second copy of the baseline (the whole build directory, at a path of the same
length) runs in every round beside the two, through all six orders: its ratios to the baseline show
what the method reports for identical code, and a Mann-Whitney test tells whether the candidate's
ratios separate from them.

Build each variant in its own Release directory with

    tools/cpp configure release -B <dir>
    tools/cpp build release -B <dir> -- --target telar-runtime runtime-probe

and pass the two trees. The host gate of tools/benchmark_host.py discards the whole
series when another build runs or the load is too high, so start it on a quiet host.
"""
import argparse
import hashlib
import itertools
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


def separation(left, right):
    """Two-sided p of a Mann-Whitney U test between two samples, normal approximation with ties."""
    values = sorted([(value, 0) for value in left] + [(value, 1) for value in right])
    ranks = [0.0] * len(values)
    start = 0

    while start < len(values):
        end = start
        while end < len(values) and values[end][0] == values[start][0]:
            end += 1

        for index in range(start, end):
            ranks[index] = (start + end + 1) / 2

        start = end

    count, other = len(left), len(right)
    statistic = sum(rank for rank, (_, group) in zip(ranks, values) if group == 0) - count * (count + 1) / 2
    deviation = math.sqrt(count * other * (count + other + 1) / 12)
    z = (statistic - count * other / 2) / deviation

    return statistic, math.erfc(abs(z) / math.sqrt(2))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--baseline', type=Path, required=True, help='Release build directory of the baseline')
    parser.add_argument('--candidate', type=Path, required=True, help='Release build directory of the candidate')
    parser.add_argument('--output', type=Path, required=True, help='new directory for the report and the host gate')
    parser.add_argument('--case', action='append', choices=CASES, help='workload to run; repeat it for several, all by default')
    parser.add_argument('--control', type=Path, help='a copy of the baseline directory, run in every round as a third variant')
    parser.add_argument('--pairs', type=int, default=7, help='rounds; each runs every variant once')
    parser.add_argument('--sample-ms', type=float, default=200, help='target duration of each timed sample')
    parser.add_argument('--max-frames', type=int, default=20000)
    parser.add_argument('--count', action='store_true', help='count instructions and cycles per frame instead of timing')
    options = parser.parse_args()
    if not 1 <= options.pairs <= 60 or not options.sample_ms > 0 or options.max_frames < 50:
        parser.error('Expected 1..60 pairs, a positive sample duration and at least 50 frames')

    if options.count and platform.system() != 'Darwin':
        parser.error('--count reads the counters of macOS /usr/bin/time -l')

    names = ('baseline', 'candidate', 'control') if options.control else ('baseline', 'candidate')
    # The runtime's programs are in its directory of each tree.
    directories = {name: getattr(options, name).resolve() / 'src/runtime' for name in names}
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

        # Warm the page cache and the first allocations of every variant.
        for directory in directories.values():
            timed(directory, case, frames)

        pairs = []
        dumps = set()

        orders = list(itertools.permutations(names))

        for index in range(options.pairs):
            # Every variant takes every position equally often.
            order = orders[index % len(orders)] if options.control else orders[index % 2]
            pair = {}

            for name in order:
                with host.run(f'{case}-{index}-{name}'):
                    pair[name], dump = (counted if options.count else timed)(directories[name], case, frames)

                dumps.add(dump)

            pairs.append(pair)

        # The oracle: every build shows the probe the same screens.
        if len(dumps) != 1:
            raise ValueError(f'{case}: the dumps differ between runs: {sorted(dumps)}')

        result = dict(frames=frames, pairs=pairs, dump_sha256=dumps.pop())
        metrics = COUNTERS if options.count else ('ns',)

        for metric in metrics:
            value = (lambda pair, name: pair[name][metric]) if options.count else (lambda pair, name: pair[name])
            summary = {}

            for name in names:
                samples = [value(pair, name) for pair in pairs]
                summary[name] = dict(median=statistics.median(samples), range=[min(samples), max(samples)])

            ratios = {}
            for name in names[1:]:
                ratios[name] = [value(pair, name) / value(pair, 'baseline') for pair in pairs]
                if not all(math.isfinite(ratio) and ratio > 0 for ratio in ratios[name]):
                    raise ValueError(f'{case}: expected positive finite {metric}')

                summary[name].update(ratios=ratios[name], median_paired_ratio=statistics.median(ratios[name]),
                                     wins=sum(ratio < 1 for ratio in ratios[name]))

            line = f"{case:16} {metric:12} {summary['baseline']['median']:14.1f} -> {summary['candidate']['median']:14.1f} per frame  " \
                   f"ratio {summary['candidate']['median_paired_ratio']:.4f}  wins {summary['candidate']['wins']}/{options.pairs}"
            if options.control:
                statistic, p = separation(ratios['candidate'], ratios['control'])
                summary['separation'] = dict(mann_whitney_u=statistic, p=p)
                line += f"  control {summary['control']['median_paired_ratio']:.4f} wins {summary['control']['wins']}/{options.pairs}  separation p {p:.3f}"

            result[metric] = summary
            print(line, flush=True)

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
