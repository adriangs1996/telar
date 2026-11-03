#!/usr/bin/env python3
import argparse
import contextlib
import ctypes
from datetime import datetime, timezone
import hashlib
import itertools
import json
from pathlib import Path
import os
import platform
import random
import shutil
import statistics
import subprocess
import tempfile
import time


class Result(ctypes.Structure):
    _fields_ = [('length', ctypes.c_uint64), ('kind', ctypes.c_uint32), ('status', ctypes.c_uint16), ('flags', ctypes.c_uint8), ('valid', ctypes.c_uint8)]


class Input(ctypes.Structure):
    _fields_ = [('bytes', ctypes.c_char_p), ('length', ctypes.c_size_t), ('output', ctypes.c_void_p), ('payload', ctypes.c_void_p), ('capacity', ctypes.c_size_t), ('fragment', ctypes.c_size_t), ('flags', ctypes.c_uint8)]


class RelayResult(ctypes.Structure):
    _fields_ = [(name, ctypes.c_size_t) for name in ['forwarded', 'payload', 'consumed', 'heads', 'head_limits', 'chunk_limits', 'trailer_limits']] + [('valid', ctypes.c_uint8)]


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_library(path):
    library = ctypes.CDLL(str(path))
    library.analyze.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint8, ctypes.POINTER(Result)]
    library.analyze.restype = None
    library.number.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint8, ctypes.POINTER(ctypes.c_uint64)]
    library.number.restype = ctypes.c_bool
    library.relay.argtypes = [ctypes.POINTER(Input), ctypes.POINTER(RelayResult)]
    library.relay.restype = None
    library.batch.argtypes = [ctypes.POINTER(Input), ctypes.c_size_t]
    library.batch.restype = ctypes.c_uint64
    return library


def libraries(root, reference, compiler, zig, scratch):
    package = scratch / 'reference'
    shutil.copytree(reference / 'lib/httprelay', package)
    shutil.copyfile(root / 'tests/http1_reference.zig', package / 'oracle.zig')
    paths = [scratch / 'zig.dylib', scratch / 'cpp.dylib']
    subprocess.run([zig, 'build-lib', '-dynamic', '-O', 'ReleaseFast', '-lc', '--dep', 'localca', '-Mroot=' + str(package / 'oracle.zig'), '-Mlocalca=' + str(reference / 'lib/localca/root.zig'), '-femit-bin=' + str(paths[0])], check=True)
    subprocess.run([compiler, '-std=c++23', '-O3', '-dynamiclib', '-I', str(root), '-I', str(root.parents[1] / 'dlls/telar-client/include'), '-I', str(root.parents[1] / 'dlls/telar-base/include'), '-I', str(root.parents[1] / 'dlls/telar-lua/include'), '-I', str(root.parents[1] / 'dlls/telar-platform/include'), '-I', str(root.parents[1] / 'dlls/telar-plugins/include'), '-I', str(root.parents[1] / 'dlls/telar-config/include'), str(root / 'tests/http1_framing.cpp'), '-o', str(paths[1])], check=True)
    loaded = [load_library(path) for path in paths]
    return loaded, {path.stem: fingerprint(path) for path in paths}


def heads():
    lengths = ['', '0', '-0', '-00', '-0_0', '+0', '1', '01', '+1', '-1', '1_0', '1__0', '_1', '1_', '1,1', '1,2', '1,', ',1', '0x10', '18446744073709551615', '18446744073709551616', '1 0']
    encodings = ['', 'chunked', 'CHUNKED', 'gzip', 'gzip,chunked', 'chunked,gzip', 'gzip,,chunked', 'chunked,', ',chunked', ' gzip, Chunked ']
    starts = ['GET / HTTP/1.1', 'HEAD / HTTP/1.1', 'head / HTTP/1.1', 'HEAD', 'invalid', 'HTTP/1.1 200 OK', 'other 101 Upgrade', 'HTTP/1.1 100 Continue', 'HTTP/1.1 204 Empty', 'HTTP/1.1 205 Empty', 'HTTP/1.1 304 Empty', 'HTTP/1.1 099 Invalid', 'HTTP/1.1 600 Invalid', 'HTTP/1.1  200 OK']
    for start, length, encoding, flags in itertools.product(starts, lengths, encodings, [0, 1, 3]):
        yield flags, (start + '\r\nContent-Length: ' + length + '\r\nTransfer-Encoding: ' + encoding + '\r\n\r\n').encode()
    generator = random.Random(0x48545450)
    fields = ['Content-Length: ' + length for length in lengths] + ['Transfer-Encoding: ' + encoding for encoding in encodings]
    fields += ['Connection: keep-alive, CLOSE', 'Connection: , close,', 'Connection: closed', 'connection : Close', 'No colon', ' : ignored', '\tcontent-length\t:\t1\t', 'X: value']
    for _ in range(20000):
        chosen = generator.choices(fields, k=generator.randrange(7))
        start = generator.choice(starts)
        if generator.randrange(4) == 0:
            start = 'HTTP/1.1 ' + str(generator.randrange(700)) + ' Result'
        yield generator.choice([0, 1, 3]), (start + '\r\n' + '\r\n'.join(chosen) + '\r\n\r\n').encode()


def numbers():
    explicit = ['', '+', '-', '0', '-0', '-00', '-0_0', '+0', '1__0', '_0', '0_', '0x10', '18446744073709551615', '18446744073709551616', 'ffffffffffffffff', '10000000000000000']
    for base, text in itertools.product([10, 16], explicit):
        yield base, text.encode()
    generator = random.Random(0x4C454E)
    for _ in range(20000):
        yield generator.choice([10, 16]), ''.join(generator.choices('0123456789abcdefABCDEF_+-x \t', k=generator.randrange(1, 23))).encode()


def messages():
    chunked = b'POST /upload HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n'
    fixtures = [(0, chunked + body) for body in [
        b'0\r\n\r\n', b'3\r\none\r\n0\r\n\r\nnext', b'+3;extra=true\r\noneXX0\r\nTrailer: value\r\n\r\n',
        b'3 ;extra\r\none\r\n0\r\n\r\n', b'1_0\r\n' + b'a' * 16 + b'\r\n0\r\n\r\n', b'-0\r\n\r\n',
        b'123', b'', b'wrong\r\n', b'a' * 1025, b'0\r\n' + b'a' * 8193,
        b'1;' + b'x' * 1020 + b'\r\na\r\n0\r\n\r\n', b'0\r\nX:' + b'x' * 8188 + b'\r\n\r\n',
    ]]
    fixtures += [(flags, (b'HTTP/1.1 200 OK' if flags & 1 else b'POST /upload HTTP/1.1') + b'\r\nContent-Length: ' + str(length).encode() + b'\r\n\r\n' + b'x' * actual) for flags, length, actual in itertools.product([0, 1, 3], [0, 1, 16384, 65536], [0, 1, 16383, 65537])]
    fixtures += [(1, b'HTTP/1.1 200 OK\r\n\r\n' + b'data' * 10000), (0, b'X' * 65536), (0, b'X' * 65532 + b'\r\n\r\n'), (0, b'GET / HTTP/1.1\r\nContent-Length: invalid\r\n\r\nbody')]
    for flags, message in fixtures:
        for fragment in [1, 2, 7, 16384, 65536]:
            yield flags, fragment, message
    generator = random.Random(0x424F4459)
    for _ in range(2000):
        body = b''
        for _ in range(generator.randrange(1, 8)):
            payload = generator.randbytes(generator.randrange(1, 512))
            body += format(len(payload), 'x').encode() + b';extension=value\r\n' + payload + b'\r\n'
        body += b'0\r\nTrailer: value\r\n\r\n'
        if generator.randrange(3) == 0:
            body = body[:generator.randrange(len(body))]
        yield 0, generator.choice([1, 7, 16384]), chunked + body


def relay_values(library, flags, fragment, text):
    capacity = max(len(text), 1)
    output = ctypes.create_string_buffer(capacity)
    payload = ctypes.create_string_buffer(capacity)
    request = Input(text, len(text), ctypes.addressof(output), ctypes.addressof(payload), capacity, fragment, flags)
    result = RelayResult()
    library.relay(ctypes.byref(request), ctypes.byref(result))
    values = {name: getattr(result, name) for name, _ in RelayResult._fields_}
    values['wire_sha256'] = hashlib.sha256(output.raw[:result.forwarded]).hexdigest()
    values['body_sha256'] = hashlib.sha256(payload.raw[:result.payload]).hexdigest()
    return values


def measure(loaded, baseline_name='zig'):
    cases = {
        'empty-request': (b'GET / HTTP/1.1\r\nHost: fixture.test\r\n\r\n', 100000),
        'small-body': (b'POST / HTTP/1.1\r\nContent-Length: 64\r\n\r\n' + b'x' * 64, 100000),
        'large-body': (b'POST / HTTP/1.1\r\nContent-Length: 65536\r\n\r\n' + b'x' * 65536, 10000),
        'large-head': (b'GET / HTTP/1.1\r\nX: ' + b'x' * 16000 + b'\r\n\r\n', 20000),
        'chunked': (b'POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n' + (b'400\r\n' + b'x' * 1024 + b'\r\n') * 64 + b'0\r\n\r\n', 5000),
    }
    results = {}
    for name, (text, iterations) in cases.items():
        oracle = [relay_values(library, 0, 16384, text) for library in loaded]
        if oracle[0] != oracle[1]:
            raise RuntimeError(f'Performance fixture differs: {name}: {oracle}')
        output = ctypes.create_string_buffer(len(text))
        payload = ctypes.create_string_buffer(len(text))
        request = Input(text, len(text), ctypes.addressof(output), ctypes.addressof(payload), len(text), 16384, 0)
        for library in loaded:
            library.batch(ctypes.byref(request), 100)
        pairs = []
        for index in range(7):
            samples = {}
            checksums = []
            for implementation in ([0, 1] if index % 2 == 0 else [1, 0]):
                started = time.perf_counter_ns()
                checksum = loaded[implementation].batch(ctypes.byref(request), iterations)
                elapsed = time.perf_counter_ns() - started
                checksums.append(checksum)
                samples[baseline_name if implementation == 0 else 'cpp'] = elapsed / iterations
            if checksums[0] != checksums[1]:
                raise RuntimeError(f'Batch checksums differ: {name}')
            samples['ratio'] = samples['cpp'] / samples[baseline_name]
            pairs.append(samples)
        wins = sum(pair['ratio'] < 1 for pair in pairs)
        ratio = statistics.median(pair['ratio'] for pair in pairs)
        results[name] = {'iterations': iterations, 'pairs': pairs, 'wins': wins, 'median_ratio': ratio, 'accepted': wins >= 6, 'oracle': oracle[0]}
        print(f'{name}: {wins}/7, cpp/{baseline_name}={ratio:.3f}', flush=True)
    return results


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description='Compare C++ HTTP framing with the unmodified Zig analyzer')
    parser.add_argument('--reference', type=Path, default=root.parents[1])
    parser.add_argument('--compiler', default='/opt/homebrew/opt/llvm/bin/clang++')
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--performance', action='store_true')
    parser.add_argument('--artifacts', type=Path)
    parser.add_argument('--baseline-cpp', type=Path)
    arguments = parser.parse_args()
    report = {'measured_at': datetime.now(timezone.utc).isoformat(), 'reference_commit': subprocess.check_output(['git', '-C', str(arguments.reference), 'rev-parse', 'HEAD'], text=True).strip(), 'head_cases': 0, 'number_cases': 0, 'message_cases': 0, 'failures': []}
    if arguments.artifacts:
        arguments.artifacts.mkdir(parents=True, exist_ok=False)
    storage = contextlib.nullcontext(arguments.artifacts) if arguments.artifacts else tempfile.TemporaryDirectory(prefix='telar-http1-oracle-')
    with storage as temporary:
        loaded, hashes = libraries(root, arguments.reference, arguments.compiler, arguments.zig, Path(temporary))
        report['libraries'] = hashes
        for flags, text in heads():
            values = []
            for library in loaded:
                result = Result()
                library.analyze(text, len(text), flags, ctypes.byref(result))
                values.append([getattr(result, name) for name, _ in Result._fields_])
            report['head_cases'] += 1
            if values[0] != values[1]:
                report['failures'].append({'head': text.decode(), 'flags': flags, 'zig': values[0], 'cpp': values[1]})
        for base, text in numbers():
            values = []
            for library in loaded:
                value = ctypes.c_uint64()
                valid = library.number(text, len(text), base, ctypes.byref(value))
                values.append([valid, value.value if valid else None])
            report['number_cases'] += 1
            if values[0] != values[1]:
                report['failures'].append({'number': text.decode(), 'base': base, 'zig': values[0], 'cpp': values[1]})
        for flags, fragment, text in messages():
            values = [relay_values(library, flags, fragment, text) for library in loaded]
            report['message_cases'] += 1
            if values[0] != values[1]:
                report['failures'].append({'message_sha256': hashlib.sha256(text).hexdigest(), 'bytes': len(text), 'flags': flags, 'fragment': fragment, 'zig': values[0], 'cpp': values[1]})
        if arguments.performance and not report['failures']:
            report['platform'] = platform.platform()
            report['load'] = os.getloadavg()
            report['measurement'] = 'In-memory message relay, persistent C++ connection storage, no TLS or socket timing'
            if arguments.baseline_cpp:
                report['baseline_cpp'] = {'path': str(arguments.baseline_cpp), 'sha256': fingerprint(arguments.baseline_cpp)}
                report['paired'] = measure([load_library(arguments.baseline_cpp), loaded[1]], 'baseline')
            report['performance'] = measure(loaded)
    sources = [*root.glob('http1/*.hpp'), root.parents[1] / 'dlls/telar-base/include/telar_base/text/fields.hpp', root / 'platform/delimited_read.hpp', root / 'tests/http1_framing.cpp', root / 'tests/http1_reference.zig', *arguments.reference.glob('lib/httprelay/**/*.zig')]
    report['sources'] = {str(path): fingerprint(path) for path in sources}
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key in ['head_cases', 'number_cases', 'message_cases']} | {'failures': len(report['failures'])}))
    raise SystemExit(bool(report['failures']) or any(not case['accepted'] for case in report.get('performance', {}).values()))


if __name__ == '__main__':
    main()
