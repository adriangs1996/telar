#!/usr/bin/env python3
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import itertools
import json
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import time


UNLIMITED = 2 ** 64 - 1


class Operation(ctypes.Structure):
    _fields_ = [('bytes', ctypes.c_char_p), ('length', ctypes.c_size_t),
                ('kind', ctypes.c_uint32), ('slot', ctypes.c_uint32)]


class Input(ctypes.Structure):
    _fields_ = [('operations', ctypes.POINTER(Operation)), ('count', ctypes.c_size_t),
                ('part_limit', ctypes.c_size_t), ('exchange_limit', ctypes.c_size_t),
                ('total_limit', ctypes.c_size_t), ('fail_allocation', ctypes.c_size_t),
                ('output', ctypes.c_void_p), ('output_capacity', ctypes.c_size_t), ('enabled', ctypes.c_uint8)]


class Result(ctypes.Structure):
    _fields_ = [('length', ctypes.c_size_t), ('allocation_calls', ctypes.c_size_t),
                ('retained_allocations', ctypes.c_size_t), ('retained_quota', ctypes.c_size_t), ('overflow', ctypes.c_uint8)]


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_library(path):
    library = ctypes.CDLL(str(path))
    library.capture.argtypes = [ctypes.POINTER(Input), ctypes.POINTER(Result)]
    library.capture.restype = None
    library.batch.argtypes = [ctypes.POINTER(Input), ctypes.c_size_t]
    library.batch.restype = ctypes.c_uint64
    return library


def build(root, arguments):
    directory = arguments.artifacts.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    shutil.copytree(arguments.reference / 'lib/exchangecapture', directory / 'reference')
    shutil.copyfile(root / 'tests/capture_reference.zig', directory / 'oracle.zig')
    subprocess.run([arguments.zig, 'build-lib', '-dynamic', '-O', 'ReleaseFast', '-lc',
                    '--dep', 'capture', '-Mroot=' + str(directory / 'oracle.zig'),
                    '-Mcapture=' + str(directory / 'reference/root.zig'),
                    '-femit-bin=' + str(directory / 'zig.dylib')], check=True)
    subprocess.run([arguments.compiler, '-std=c++23', '-O3', '-dynamiclib', '-I', str(root), '-I', str(root.parents[1] / 'dlls/telar-client/include'), '-I', str(root.parents[1] / 'dlls/telar-base/include'), '-I', str(root.parents[1] / 'dlls/telar-lua/include'), '-I', str(root.parents[1] / 'dlls/telar-platform/include'), '-I', str(root.parents[1] / 'dlls/telar-plugins/include'), '-I', str(root.parents[1] / 'dlls/telar-config/include'),
                    str(root / 'tests/capture_storage.cpp'), '-o', str(directory / 'cpp.dylib')], check=True)
    return [load_library(directory / name) for name in ['zig.dylib', 'cpp.dylib']]


def fixture(operations, part=16384, exchange=32768, total=131072, fail=UNLIMITED, enabled=1):
    return operations, part, exchange, total, fail, enabled


def fixtures():
    for side, part, exchange, total in itertools.product([0, 1], [1, 31, 256, 513, 16384], [2, 63, 512, 1024, 32768], [0, 127, 256, 600, 65536]):
        operations = [(side, 0, b'example.test'), (2 + side * 2, 0, b'h' * 31),
                      (3 + side * 2, 0, b'b' * 257), (3 + side * 2, 0, b'c' * 1024),
                      (7, 0, b''), (2 + side * 2, 0, b'head'), (8, 0, b''),
                      (3 + side * 2, 0, b'body'), (12, 0, b'finished')]
        for fail in [UNLIMITED, 0, 1, 2, 3, 5]:
            yield fixture(operations, part, exchange, total, fail)

    for kind, sizes in [(0, [0, 254, 255, 256]), (9, [0, 31, 32, 33]),
                        (10, [0, 8191, 8192, 8193]), (11, [0, 127, 128, 129])]:
        for size in sizes:
            yield fixture([(0, 0, b'host'), (9, 0, b'GET'), (10, 0, b'/'), (kind, 0, b'x' * size)])
    for head in [b'', b'GET', b'GET\r\nContent-Encoding: gzip\r\n\r\n',
                 b'POST / HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Encoding: br\r\n\r\n',
                 b'  / HTTP/1.1\r\n CONTENT-ENCODING :\t identity \t\r\n\r\n',
                 b'HTTP/1.1 200 OK\r\nContent-Encoding: gzip, br\r\n\r\n']:
        for side in [0, 1]:
            yield fixture([(side, 0, b'host'), (6, 0, head)])
    yield fixture([(0, 0, b'host'), (6, 0, b'GET / HTTP/1.1\r\n\r\n')], enabled=0)

    randomizer = random.Random(0x43415054555245)
    fragments = [b'', b'h', b'x' * 255, b'y' * 256, b'z' * 257, b'p' * 1000,
                 b'GET /a HTTP/1.1\r\nContent-Encoding: gzip\r\n\r\n', b'gzip', b'deflate, br']
    for index in range(3000):
        operations = [(randomizer.randrange(2), slot, b'host') for slot in range(4)]
        operations += [(randomizer.randrange(14), randomizer.randrange(4), randomizer.choice(fragments))
                       for _ in range(randomizer.randrange(1, 48))]
        yield fixture(operations, randomizer.choice([1, 32, 256, 1024, 8192]),
                      randomizer.choice([2, 63, 1024, 8192]), randomizer.choice([1, 256, 600, 1024, 32768]),
                      randomizer.randrange(20) if index % 2 else UNLIMITED)


def request(case):
    operations, part, exchange, total, fail, enabled = case
    values = (Operation * len(operations))(*[Operation(data, len(data), kind, slot) for kind, slot, data in operations])
    capacity = max(65536, len(operations) * 128 + sum(len(data) for _, _, data in operations) + 65536)
    output = ctypes.create_string_buffer(capacity)
    value = Input(values, len(values), part, exchange, total, fail, ctypes.addressof(output), capacity, enabled)
    return value, values, output


def evaluate(library, case):
    value, operations, output = request(case)
    result = Result()
    library.capture(ctypes.byref(value), ctypes.byref(result))
    if result.overflow or result.retained_allocations or result.retained_quota:
        raise RuntimeError('Capture oracle overflow or retained ownership')
    return tuple(getattr(result, name) for name, _ in Result._fields_), output.raw[:result.length]


def measure(libraries):
    cases = {
        'small': fixture([(0, 0, b'host'), (6, 0, b'POST / HTTP/1.1\r\n\r\n'), (3, 0, b'x' * 512)]),
        'large': fixture([(0, 0, b'host'), (3, 0, b'x' * (1024 * 1024))], 2 * 1024 * 1024, 4 * 1024 * 1024, 8 * 1024 * 1024),
        'fragmented': fixture([(0, 0, b'host')] + [(3, 0, b'x' * 64)] * 128),
        'quota-pressure': fixture([(0, 0, b'host')] + [(3, 0, b'x' * 64)] * 32, 8192, 16384, 600),
        'metadata': fixture([(0, 0, b'host'), (6, 0, b'POST /v1/messages HTTP/1.1\r\nContent-Encoding: gzip\r\nX-Request: 1234\r\n\r\n')]),
    }
    report = {}
    for name, case in cases.items():
        if evaluate(libraries[0], case) != evaluate(libraries[1], case):
            raise RuntimeError('Benchmark output differs: ' + name)
        value, operations, output = request(case)
        iterations = 500 if name == 'large' else 10000
        for library in libraries:
            library.batch(ctypes.byref(value), 100)
        pairs = []
        for pair in range(7):
            elapsed = {}
            checksums = []
            for index in ([0, 1] if pair % 2 == 0 else [1, 0]):
                started = time.perf_counter_ns()
                checksums.append(libraries[index].batch(ctypes.byref(value), iterations))
                elapsed['zig' if index == 0 else 'cpp'] = (time.perf_counter_ns() - started) / iterations
            if checksums[0] != checksums[1]:
                raise RuntimeError('Benchmark checksums differ: ' + name)
            elapsed['ratio'] = elapsed['cpp'] / elapsed['zig']
            pairs.append(elapsed)
            print(name, pair + 1, round(elapsed['ratio'], 3), flush=True)
        report[name] = {'iterations': iterations, 'pairs': pairs,
                        'wins': sum(pair['ratio'] <= 1 for pair in pairs),
                        'median_ratio': statistics.median(pair['ratio'] for pair in pairs)}
    return report


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument('--reference', type=Path, default=root.parents[1])
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compiler', default='/opt/homebrew/opt/llvm/bin/clang++')
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--performance', action='store_true')
    arguments = parser.parse_args()
    report = {'measured_at': datetime.now(timezone.utc).isoformat(), 'platform': platform.platform(), 'cases': 0}
    try:
        libraries = build(root, arguments)
        report['binaries'] = {name: fingerprint(arguments.artifacts / (name + '.dylib')) for name in ['zig', 'cpp']}
        report['sources'] = {str(path.relative_to(root)): fingerprint(path) for path in sorted((root / 'exchange_capture').glob('*.hpp'))}
        digest = hashlib.sha256()
        for index, case in enumerate(fixtures()):
            baseline = evaluate(libraries[0], case)
            candidate = evaluate(libraries[1], case)
            if candidate != baseline:
                report['failed_case'] = {'index': index, 'limits': case[1:],
                                         'operations': [(kind, slot, data.hex()) for kind, slot, data in case[0]],
                                         'zig': baseline[0], 'cpp': candidate[0]}
                for name, result in [('zig', baseline), ('cpp', candidate)]:
                    arguments.output.with_suffix('.' + name + '.bin').write_bytes(result[1])
                raise RuntimeError(f'Capture storage differs in case {index}')
            digest.update(baseline[1])
            report['cases'] += 1
        report['output_sha256'] = digest.hexdigest()
        print('Equivalent capture cases:', report['cases'], flush=True)
        if arguments.performance:
            report['performance'] = measure(libraries)
    except Exception as error:
        report['failure'] = str(error)
        raise
    finally:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    if arguments.performance and any(case['wins'] < 6 for case in report['performance'].values()):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
