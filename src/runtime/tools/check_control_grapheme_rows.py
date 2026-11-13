#!/usr/bin/env python3
"""Isolated-process application differential for dense/sparse grapheme rows."""
import argparse
import ctypes
import datetime
import hashlib
import json
import multiprocessing
from pathlib import Path
import sys
from control_query_oracle import Probe, GHOSTTY, ForeignResponse

CSI = b'\x1b['


def worker(connection, path):
    try:
        library_probe = None
        output = ctypes.create_string_buffer(512)
        connection.send({'ready': True})
        while (request := connection.recv()) is not None:
            geometry, seed, seed_split, query, query_split = request
            library_probe = Probe(path, geometry)
            try:
                library_probe.policy(2)
                for data, split in [(seed, seed_split), (query, query_split)]:
                    for part in [data] if split is None else [data[:split], data[split:]]:
                        library_probe.feed(part)
                reply = bytearray()
                while size := library_probe.lib.query_probe_drain(library_probe.ptr, output, len(output)):
                    reply.extend(output.raw[:size])
                if library_probe.foreign_calls and library_probe.foreign_calls(library_probe.ptr):
                    raise ForeignResponse(bytes(reply), library_probe.foreign_calls(library_probe.ptr))
                connection.send({'reply': bytes(reply)})
            finally:
                library_probe.close()
                library_probe = None
    except BaseException as error:
        connection.send({'error': repr(error)})
    finally:
        connection.close()


class RemoteProbe:
    def __init__(self, path):
        context = multiprocessing.get_context('spawn')
        self.connection, child = context.Pipe()
        self.process = context.Process(target=worker, args=(child, path))
        self.process.start()
        child.close()
        if not self.connection.recv().get('ready'):
            raise RuntimeError('Worker did not initialize')

    def send(self, request):
        self.connection.send(request)

    def receive(self):
        result = self.connection.recv()
        if 'error' in result:
            raise RuntimeError(result['error'])
        return result['reply']

    def close(self):
        if self.process.is_alive():
            try:
                self.connection.send(None)
            except (BrokenPipeError, EOFError, OSError):
                pass
            self.process.join(timeout=2)
            if self.process.is_alive():
                self.process.terminate()
                self.process.join()
        self.connection.close()


def rows():
    for columns in [16, 80, 257]:
        for density in sorted({min(columns, value) for value in [1, 7, 8, 9, 16, 80]}):
            for length in [1, 4, 32]:
                cluster = ''.join('\u0301' if index % 2 == 0 else '\u0327' for index in range(length)).encode()
                seed = (b'A' + cluster) * density + b'A' * (columns - density)
                yield f'row-{columns}-{density}-{length}', columns, seed, False
    dense = ('A\u0301' * 9 + '界\u0327' * 9).encode()
    yield 'styled-wide', 80, CSI + b'1;3m' + dense + CSI + b'0m', True
    yield 'protected-wide', 80, CSI + b'1"q' + dense + CSI + b'0"q', False
    yield 'origin-wide', 80, CSI + b'3;20r' + CSI + b'?6h' + dense, False
    yield 'alternate-wide', 80, CSI + b'?1049h' + dense, False
    cluster = ('\u0301\u0327' * 32).encode()
    yield 'batch-257-dense-64', 257, (b'A' + cluster) * 257, False
    yield 'state-cap-16-chain-512', 16, b'A' + ('\u0301\u0327' * 256).encode() + b'A' * 15, False
    supplementary = '\U0001d185'.encode()
    yield 'last-columns-256', 256, b'A' * 248 + (b'A' + supplementary) * 8, False
    varied = [b'A' * 248 + (b'A' + supplementary) * 8,
              (b'A' + cluster) * 256, (b'A' + supplementary) * 256]
    yield 'varied-rows-256', 256, b'\r\n'.join(varied), False
    styled = b''.join((CSI + (b'1;3m' if column % 13 == 0 else b'0m') + b'A' + cluster[:2])
                      for column in range(300))
    yield 'styled-selected-300', 300, styled, False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--reference', type=Path, default=GHOSTTY)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    libraries = [path.resolve() for path in [args.native, args.baseline, args.reference]]
    remotes = []
    checked = 0
    query_splits = 0
    seed_splits = 0
    baseline_differences = 0
    application_differences = 0
    failures = []
    inputs = {}
    try:
        for path in libraries:
            remotes.append(RemoteProbe(path))
        for name, columns, seed, split_seed in rows():
            bottom = 3 if name == 'varied-rows-256' else 1
            left = 3 if name == 'styled-selected-300' else 1
            for flags in range(32):
                query = (CSI + str(flags).encode() + b'#y' + CSI + f'7;1;1;{left};{bottom};{columns}*y'.encode() +
                         CSI + f'1;{left}H'.encode() + b'B' + CSI + f'8;1;1;{left};{bottom};{columns}*y'.encode())
                if name == 'alternate-wide':
                    query += CSI + b'?1049l' + CSI + f'9;1;1;1;1;{columns}*y'.encode()
                key = f'{name}-flags-{flags}'
                inputs[key] = hashlib.sha256(seed + query).hexdigest()
                partitions = [(None, None), *[(None, split) for split in range(len(query) + 1)]]
                if split_seed or name in ['row-80-9-1', 'row-80-80-4', 'row-257-8-1']:
                    partitions.extend((split, None) for split in range(len(seed) + 1))
                for seed_split, query_split in partitions:
                    request = ((columns, 24, 9, 18), seed, seed_split, query, query_split)
                    for remote in remotes:
                        remote.send(request)
                    replies = [remote.receive() for remote in remotes]
                    checked += 1
                    query_splits += query_split is not None
                    seed_splits += seed_split is not None
                    baseline_differences += replies[0] != replies[1]
                    application_differences += replies[0] != replies[2]
                    if replies[0] != replies[1] or replies[0] != replies[2]:
                        if len(failures) < 30:
                            failures.append({'case': key, 'seed_split': seed_split, 'query_split': query_split,
                                             'responses': [value.hex() for value in replies]})
    finally:
        for remote in remotes:
            remote.close()
    report = {'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'checked': checked, 'query_split_cases': query_splits, 'seed_split_cases': seed_splits,
              'candidate_vs_baseline_differences': baseline_differences,
              'candidate_vs_application_differences': application_differences, 'failures': failures,
              'libraries_in_separate_processes': True,
              'libraries': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in libraries},
              'input_sha256': inputs, 'harness_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'command': sys.argv,
              'scope': 'Response bytes and zero foreign native callbacks; all checksum flags and query split boundaries. Selected dense/wide/large-column seeds also split at every byte. Each request receives fresh real terminal state. Separate processes prevent C++ weak-symbol coalescing between variants.'}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ['checked', 'candidate_vs_baseline_differences', 'candidate_vs_application_differences']}))
    return bool(baseline_differences or application_differences)


if __name__ == '__main__':
    sys.exit(main())
