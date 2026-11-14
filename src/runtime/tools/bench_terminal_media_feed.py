#!/usr/bin/env python3
"""Alternate two builds of terminal-media-feed-probe: Terminal::feed on a pane with media.

The probe feeds a separate_media terminal with a PaneMedia attached, as a pane in
client_layouts does, and pumps the media and the replies after every feed. Each sample is
the probe's own timer around that loop, in ns per iteration of the workload.

Build each variant in its own Release directory with

    tools/cpp configure runtime -B <dir> --config Release
    tools/cpp build runtime -B <dir> -- --target terminal-media-feed-probe

and pass the two directories. The host gate of tools/benchmark_host.py discards the whole
series when another build runs or the load is too high, so start it on a quiet host.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'tools'))
from benchmark_host import HostLoadGate

PROBE = 'terminal-media-feed-probe'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def probe(binary, *arguments):
    return subprocess.run([str(binary), *map(str, arguments)], check=True, capture_output=True, text=True, timeout=120).stdout


def sample(binary, case, iterations):
    elapsed, replies = probe(binary, case, iterations).split()
    return int(elapsed), replies


def iterations_for(binaries, case, target_ns, maximum):
    # The slower variant sets the count, so both samples take at least the target.
    per_iteration = max(sample(binary, case, 100)[0] / 100 for binary in binaries.values())
    return max(100, min(maximum, int(target_ns / max(per_iteration, 1))))


def main(probe_name=PROBE, description=__doc__):
    """Alternate the two builds of probe_name; bench_command_capture.py runs it for its own probe."""
    parser = argparse.ArgumentParser(description=description, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--baseline', type=Path, required=True, help='Release build directory of the baseline')
    parser.add_argument('--candidate', type=Path, required=True, help='Release build directory of the candidate')
    parser.add_argument('--output', type=Path, required=True, help='new directory for the report and the host gate')
    parser.add_argument('--case', action='append', help='workload to run; repeat it for several, all by default')
    parser.add_argument('--pairs', type=int, default=7)
    parser.add_argument('--sample-ms', type=float, default=40, help='target duration of each timed sample')
    parser.add_argument('--max-iterations', type=int, default=200000)
    options = parser.parse_args()
    if not 1 <= options.pairs <= 31 or not options.sample_ms > 0 or options.max_iterations < 100:
        parser.error('Expected 1..31 pairs, a positive sample duration and at least 100 iterations')

    binaries = {name: (getattr(options, name) / probe_name).resolve() for name in ('baseline', 'candidate')}
    for name, binary in binaries.items():
        if not binary.is_file():
            parser.error(f'No {probe_name} in the {name} directory; build it with --target {probe_name}')

    cases = probe(binaries['baseline'], '--list').split()
    if probe(binaries['candidate'], '--list').split() != cases:
        raise ValueError('The two probes list different workloads')

    for case in options.case or []:
        if case not in cases:
            parser.error(f'Unknown case {case}; expected one of {", ".join(cases)}')

    directory = options.output.resolve()

    directory.mkdir(parents=True, exist_ok=False)
    host = HostLoadGate(directory / 'host-load.json')
    host.checkpoint('before-series')
    manifest = dict(binaries={name: dict(path=str(path), sha256=digest(path)) for name, path in binaries.items()},
                    command_line=sys.argv, uptime=subprocess.check_output(['uptime'], text=True).strip())
    (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    results = {}

    for case in options.case or cases:
        iterations = iterations_for(binaries, case, options.sample_ms * 1e6, options.max_iterations)

        # Warm the page cache and the probe's first allocations of both variants.
        for binary in binaries.values():
            sample(binary, case, iterations)

        pairs = []
        replies = set()

        for index in range(options.pairs):
            order = ['baseline', 'candidate'] if index % 2 == 0 else ['candidate', 'baseline']
            pair = {}

            for name in order:
                with host.run(f'{case}-{index}-{name}'):
                    elapsed, digest_value = sample(binaries[name], case, iterations)

                pair[name] = elapsed / iterations
                replies.add(digest_value)

            pairs.append(pair)

        # The oracle: both builds answer the workload with the same bytes.
        if len(replies) != 1:
            raise ValueError(f'{case}: the replies differ between runs: {sorted(replies)}')

        ratios = [pair['candidate'] / pair['baseline'] for pair in pairs]
        if not all(math.isfinite(ratio) for ratio in ratios):
            raise ValueError(f'{case}: expected finite durations')

        wins = sum(ratio < 1 for ratio in ratios)
        results[case] = dict(iterations=iterations, pairs=pairs, replies_fnv1a=replies.pop(),
                             baseline_median_ns=statistics.median(pair['baseline'] for pair in pairs),
                             candidate_median_ns=statistics.median(pair['candidate'] for pair in pairs),
                             median_paired_ratio=statistics.median(ratios), candidate_wins=wins)
        print(f"{case:24} {results[case]['baseline_median_ns']:12.1f} -> {results[case]['candidate_median_ns']:12.1f} ns/iteration  "
              f"ratio {results[case]['median_paired_ratio']:.4f}  wins {wins}/{options.pairs}", flush=True)

    host.finish()
    for name, path in binaries.items():
        if digest(path) != manifest['binaries'][name]['sha256']:
            raise ValueError(f'The {name} probe changed during the comparison')

    report = dict(manifest=manifest, results=results,
                  acceptance='The target case wins at least 6 of 7 pairs and no workload loses consistently '
                             '(0-1 wins) unless the loss is proven to be code placement.')

    (directory / 'result.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
