#!/usr/bin/env python3
"""Allocator requests and explicit sink copies; deliberately not a timing run."""
import argparse
import ctypes
import datetime
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile

from bench_control_queries import WORKLOADS
from control_query_oracle import Probe


def verify_output(library, data, iterations, fragment, setup, warmup):
    probe = Probe(library)
    buffer = ctypes.create_string_buffer(65536)
    total = 0
    fingerprint = 14695981039346656037

    def feed(payload, observe=False):
        nonlocal total, fingerprint
        for offset in range(0, len(payload), fragment or len(payload)):
            probe.feed(payload[offset:offset + (fragment or len(payload))])
            while count := probe.lib.query_probe_drain(probe.ptr, buffer, len(buffer)):
                if observe:
                    total += count
                    for byte in buffer.raw[:count]:
                        fingerprint = ((fingerprint ^ byte) * 1099511628211) & ((1 << 64) - 1)

    try:
        probe.policy(2 if setup else 0)
        if setup >= 2:
            cell = b'A' if setup == 2 else b'\x1b[1;3mA\x1b[0mB' if setup == 3 else 'Á'.encode()
            for _ in range(80 * 24 // 2 if setup == 3 else 80 * 24):
                feed(cell)
            if setup == 4:
                feed(b'\x1b[4#y')
        for _ in range(warmup):
            feed(data)
        for _ in range(iterations):
            feed(data, True)
        if probe.foreign_calls and probe.foreign_calls(probe.ptr):
            raise RuntimeError('Accounting verification reached a foreign query handler')
        return {'sink_copy_bytes': total, 'output_fnv1a': fingerprint}
    finally:
        probe.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--verify-library', type=Path)
    parser.add_argument('--iterations', type=int, default=100)
    parser.add_argument('--warmup', type=int, default=100)
    parser.add_argument('--case', action='append', choices=WORKLOADS)
    parser.add_argument('--copy-boundaries', action='store_true')
    args = parser.parse_args()
    if not 1 <= args.iterations <= 100000 or not 0 <= args.warmup <= 100000:
        parser.error('Iteration counts exceed the accounting probe bounds')
    results = {}
    probe = args.probe.resolve()
    with tempfile.TemporaryDirectory(prefix='telar-control-accounting-') as directory:
        payload = Path(directory) / 'payload.bin'
        for name, (data, units, fragment) in WORKLOADS.items():
            if args.case and name not in args.case:
                continue
            setup = {'checksum-ascii-screen': 2, 'checksum-styled-screen': 3,
                     'checksum-grapheme-screen': 4}.get(name, int(name.startswith('checksum-')))
            payload.write_bytes(data)
            cases = {}
            for label, warmup in [('cold', 0), ('warm', args.warmup)]:
                command = [str(probe), str(payload), str(args.iterations), str(fragment), str(setup), str(warmup)]
                run = subprocess.run(command, check=True, capture_output=True, text=True, timeout=60)
                result = json.loads(run.stdout)
                if result['version'] != (2 if args.copy_boundaries else 1) or len(result['phases']) != 5:
                    raise RuntimeError('Unexpected accounting ABI')
                if args.copy_boundaries and any(len(phase['copy_boundaries']) != 5 for phase in result['phases']):
                    raise RuntimeError('Unexpected copy-boundary layout')
                if result['phases'][-1]['live_end'] != 0:
                    raise RuntimeError('Owned allocation lifetime was not balanced')
                result['warmup_iterations'] = warmup
                result['stderr'] = run.stderr
                if args.verify_library:
                    expected = verify_output(args.verify_library, data, args.iterations, fragment, setup, warmup)
                    if any(result[key] != value for key, value in expected.items()):
                        raise RuntimeError(f'Accounting fixture output differs from full Terminal: {name}, {label}')
                    result['output_verified_against_full_terminal'] = True
                cases[label] = result
            results[name] = {'input_sha256': hashlib.sha256(data).hexdigest(),
                             'input_bytes': len(data), 'units_per_iteration': units,
                             'fragment': fragment, 'setup': setup, 'runs': cases}
            print(name, cases['warm']['phases'][3]['successes'],
                  cases['warm']['phases'][3]['requested_bytes'], flush=True)
    root = Path(__file__).resolve().parents[1]
    sources = ['tests/control_accounting_probe.cpp', 'tests/control_component_probe.cpp',
               'tools/account_control_queries.py', 'tools/bench_control_queries.py',
               'terminal/control/engine.hpp', 'terminal/control/vt_state.hpp',
               'terminal/ghostty_allocator.hpp', 'memory/allocator.hpp']
    report = {'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'architecture': platform.machine(), 'iterations': args.iterations,
              'probe': str(probe), 'probe_sha256': hashlib.sha256(probe.read_bytes()).hexdigest(),
              'verification_library': str(args.verify_library) if args.verify_library else None,
              'verification_library_sha256': hashlib.sha256(args.verify_library.read_bytes()).hexdigest() if args.verify_library else None,
              'source_sha256': {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in sources},
              'phases': ['setup', 'seed', 'warmup', 'workload', 'destroy'],
              'copy_boundary_order': ['parser_retention', 'parser_growth', 'reply_materialization',
                                      'reply_growth', 'queue_publication'] if args.copy_boundaries else [],
              'scope': 'Native component fixture; allocator requests reaching the supplied Memory, explicit queue-to-sink copies'
                       + (' and selected parser/reply/queue boundaries' if args.copy_boundaries else '') + '. No latency claim.',
              'limits': ['Direct VT page mappings bypass this allocator; these peaks are not RSS.',
                         'Input and reporting allocations outside supplied Memory are excluded.',
                         'Requested bytes are not bytes copied; internal VT copies are not counted.'
                         + ('' if args.copy_boundaries else ' Parser/reply copies are not counted.'),
                         'Component fixture mirrors control_component_probe.cpp; the application uses a separate adapter and report.',
                         *(['Copy counters cover the specified parser/reply/queue boundaries only; parser retention includes synthesized framing bytes.',
                            'Vector growth counts logical bytes preserved between buffers, not physical cache/memory traffic.',
                            'Other formatter buffers, VT, graphics scanners, codecs and general process copies remain outside this instrumentation.'] if args.copy_boundaries else []),
                         'Warmup is a fixed iteration count for accounting, not the timing harness150ms warmup.'],
              'results': results}
    args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
