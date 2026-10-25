#!/usr/bin/env python3
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import time


class Input(ctypes.Structure):
    _fields_ = [('bytes', ctypes.c_char_p), ('length', ctypes.c_size_t), ('wire', ctypes.c_void_p),
                ('events', ctypes.c_void_p), ('event_capacity', ctypes.c_size_t), ('fragment', ctypes.c_size_t),
                ('fail_after', ctypes.c_size_t), ('response', ctypes.c_uint8)]


class Result(ctypes.Structure):
    _fields_ = [('forwarded', ctypes.c_size_t), ('consumed', ctypes.c_size_t), ('events', ctypes.c_size_t),
                ('untracked', ctypes.c_uint32), ('failed', ctypes.c_uint8), ('block_limit', ctypes.c_uint8),
                ('overflow', ctypes.c_uint8)]


PREFACE = b'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'
UNLIMITED = 2 ** 64 - 1


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_library(path):
    library = ctypes.CDLL(str(path))
    library.relay.argtypes = [ctypes.POINTER(Input), ctypes.POINTER(Result)]
    library.relay.restype = None
    library.batch.argtypes = [ctypes.POINTER(Input), ctypes.c_size_t]
    library.batch.restype = ctypes.c_uint64
    return library


def build(root, arguments):
    artifacts = arguments.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=False)
    package = artifacts / 'reference'
    shutil.copytree(arguments.reference / 'lib/httprelay', package)
    shutil.copyfile(root / 'tests/http2_reference.zig', package / 'oracle.zig')
    include = str(arguments.nghttp2 / 'include')
    library = str(arguments.nghttp2 / 'lib/libnghttp2.a')
    reference = arguments.reference.resolve()
    subprocess.run([arguments.zig, 'build-lib', '-dynamic', '-O', 'ReleaseFast', '-lc', library,
                    '-I', include, '--dep', 'localca', '--dep', 'h2frames', '--dep', 'cblocks',
                    '-Mroot=' + str(package / 'oracle.zig'),
                    '-Mlocalca=' + str(reference / 'lib/localca/root.zig'),
                    '-Mh2frames=' + str(reference / 'lib/h2frames/root.zig'),
                    '-Mcblocks=' + str(reference / 'lib/cblocks/root.zig'),
                    '-femit-bin=' + str(artifacts / 'zig.dylib')], check=True)
    subprocess.run([arguments.compiler, '-std=c++23', '-O3', '-dynamiclib', '-I', str(root), '-I', include,
                    str(root / 'tests/http2_framing.cpp'), library, '-o', str(artifacts / 'cpp.dylib')], check=True)
    return [load_library(artifacts / name) for name in ['zig.dylib', 'cpp.dylib']]


def frame(kind, flags, stream, payload=b''):
    return len(payload).to_bytes(3, 'big') + bytes([kind, flags]) + stream.to_bytes(4, 'big') + payload


def literal(name, value, indexed=False):
    assert len(name) < 127 and len(value) < 127
    return bytes([64 if indexed else 0, len(name)]) + name + bytes([len(value)]) + value


def fixtures():
    for response in [0, 1]:
        prefix = b'' if response else PREFACE
        head = b'\x88' if response else b'\x82\x84'
        sequences = [b'', frame(1, 5, 1, head), frame(1, 4, 1, head) + frame(0, 1, 1, b'body'),
                     frame(1, 0, 1, head[:1]) + frame(9, 4, 1, head[1:]),
                     frame(1, 0, 1, head) + frame(9, 4, 3),
                     frame(1, 0, 1, head) + frame(6, 0, 0, b'12345678'),
                     frame(1, 4, 1, head) + frame(3, 0, 1, b'\0' * 4),
                     frame(1, 4, 1, head) + frame(7, 0, 0, b'\0' * 8),
                     frame(1, 4, 0, head), frame(9, 4, 1, head),
                     frame(1, 4, 1, b'\xff') + frame(0, 1, 1, b'after failure'),
                     frame(5, 4, 1, b'\0\0\0\x02' + head) + frame(1, 5, 3, head),
                     frame(1, 4, 1, head + literal(b'x-test', b'dynamic', True)) + frame(1, 5, 3, head + b'\xbe')]
        for sequence in sequences:
            data = prefix + sequence
            for fragment in [1, 2, 3, 7, 9, 24, 16384]:
                yield data, response, fragment, UNLIMITED
                for limit in [0, len(data) // 2, len(data)]:
                    yield data, response, fragment, limit
            for length in range(len(data)):
                yield data[:length], response, 3, UNLIMITED

        for flags in [0, 1, 4, 5, 8, 9, 12, 13, 32, 36, 44, 45, 255]:
            for kind in [0, 1, 5, 9]:
                for payload in [b'', b'\0', b'\x01', b'\xff', b'\0' + head, b'\x02' + head + b'!!', b'\0' * 6 + head]:
                    for fragment in [1, 7, 16384]:
                        yield prefix + frame(kind, flags, 1, payload), response, fragment, UNLIMITED

        tracked = b''.join(frame(1, 4, index, head) for index in range(1, 131))
        for tail in [b'', frame(1, 4, 1, head), frame(3, 0, 1), frame(0, 1, 1) + frame(1, 4, 200, head)]:
            yield prefix + tracked + tail, response, 16384, UNLIMITED
        for length in [128 * 1024 - 1, 128 * 1024, 128 * 1024 + 1]:
            yield prefix + frame(1, 4, 1, b'\0' * length), response, 16384, UNLIMITED

    for value in [b'200', b'+2__00', b'-0', b'65535', b'65536', b'_200', b'200_']:
        yield frame(1, 5, 1, literal(b':status', value)), 1, 7, UNLIMITED
    for content_type in [b'text/event-stream', b' Text/Event-Stream ; charset=utf8', b'text/plain', b'']:
        for encoding in [b'identity', b'identity, IDENTITY', b'gzip', b'', b'identity,']:
            for duplicate in [False, True]:
                fields = b'\x88' + literal(b'Content-Type', content_type) + literal(b'content-encoding', encoding)
                if duplicate:
                    fields += literal(b'content-type', content_type)
                yield frame(1, 4, 1, fields) + frame(0, 1, 1, b'data: hello\n\n'), 1, 3, UNLIMITED

    randomizer = random.Random(0x4854545032)
    for index in range(6000):
        response = index % 2
        data = b'' if response else PREFACE
        for _ in range(randomizer.randint(1, 8)):
            kind = randomizer.choice([0, 1, 3, 4, 5, 6, 7, 9, 255])
            payload = randomizer.randbytes(randomizer.randint(0, 48))
            if kind == 1 and randomizer.randrange(2):
                payload = randomizer.choice([b'\x88', b'\x82\x84', b'\x40\x01x\x01y', b'\xbe', b'\x20\x88'])
            data += frame(kind, randomizer.randrange(64), randomizer.choice([0, 1, 3, 127, 0x80000001]), payload)
        if index % 3 == 0:
            data = data[:randomizer.randrange(len(data) + 1)]
        if index % 7 == 0 and data:
            position = randomizer.randrange(len(data))
            data = data[:position] + bytes([randomizer.randrange(256)]) + data[position + 1:]
        yield data, response, randomizer.choice([1, 2, 7, 16, 16384]), UNLIMITED


def request(data, response, fragment=16384, fail_after=UNLIMITED):
    wire = ctypes.create_string_buffer(max(1, len(data)))
    events = ctypes.create_string_buffer(max(65536, len(data) * 64))
    value = Input(data, len(data), ctypes.addressof(wire), ctypes.addressof(events), len(events), fragment, fail_after, response)
    return value, wire, events


def evaluate(library, fixture):
    value, wire, events = request(*fixture)
    result = Result()
    library.relay(ctypes.byref(value), ctypes.byref(result))
    if result.overflow:
        raise RuntimeError('Event oracle buffer exhausted')
    fields = tuple(getattr(result, name) for name, _ in Result._fields_)
    return fields, wire.raw[:result.forwarded], events.raw[:result.events]


def measure(libraries, baseline_name='zig'):
    cases = {
        'request-headers': (PREFACE + frame(1, 5, 1, b'\x82\x84'), 0, 16384, 10000),
        'response-headers': (frame(1, 5, 1, b'\x88'), 1, 16384, 10000),
        'multiplexed': (PREFACE + b''.join(frame(1, 5, stream, b'\x82\x84') for stream in range(1, 65)), 0, 16384, 2000),
        'large-body': (frame(1, 4, 1, b'\x88') + frame(0, 1, 1, b'x' * 65536), 1, 16384, 2000),
        'fragmented': (PREFACE + frame(1, 0, 1, b'\x82') + frame(9, 4, 1, b'\x84') + frame(0, 1, 1, b'x' * 1024), 0, 7, 2000),
    }
    output = {}
    for name, (data, response, fragment, iterations) in cases.items():
        fixture = data, response, fragment, UNLIMITED
        if evaluate(libraries[0], fixture) != evaluate(libraries[1], fixture):
            raise RuntimeError(f'Benchmark differs: {name}')
        value, wire, events = request(*fixture)
        for library in libraries:
            library.batch(ctypes.byref(value), 100)
        pairs = []
        for pair in range(7):
            elapsed = {}
            checksums = []
            for index in ([0, 1] if pair % 2 == 0 else [1, 0]):
                started = time.perf_counter_ns()
                checksums.append(libraries[index].batch(ctypes.byref(value), iterations))
                elapsed[baseline_name if index == 0 else 'cpp'] = (time.perf_counter_ns() - started) / iterations
            if checksums[0] != checksums[1]:
                raise RuntimeError(f'Benchmark checksum differs: {name}')
            elapsed['ratio'] = elapsed['cpp'] / elapsed[baseline_name]
            pairs.append(elapsed)
        wins = sum(pair['ratio'] < 1 for pair in pairs)
        ratio = statistics.median(pair['ratio'] for pair in pairs)
        output[name] = {'iterations': iterations, 'pairs': pairs, 'wins': wins, 'median_ratio': ratio, 'accepted': wins >= 6}
        print(f'{name}: {wins}/7, cpp/{baseline_name}={ratio:.3f}', flush=True)
    return output


def source_paths(root, arguments):
    return [*root.glob('http2/*.hpp'), root / 'proxy/relay_direction.hpp', root / 'memory/erase_sensitive.hpp', root / 'memory/c_allocation_blocks.hpp', root / 'tests/http2_oracle.hpp',
               root / 'tests/http2_framing.cpp', root / 'tests/http2_oracle_stream.hpp', root / 'tests/http2_reference.zig', *arguments.reference.glob('lib/httprelay/**/*.zig')]


def main(description="Compare HTTP/2 bytes, events and limits against the unchanged Zig relay", build_oracles=build, cases=fixtures, sources=source_paths):
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument('--reference', type=Path, default=root.parents[1])
    parser.add_argument('--compiler', default='/opt/homebrew/opt/llvm/bin/clang++')
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--nghttp2', type=Path, required=True)
    parser.add_argument('--brotli', type=Path, default=Path('/opt/homebrew/opt/brotli'))
    parser.add_argument('--zstd', type=Path, default=Path('/opt/homebrew/opt/zstd'))
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--performance', action='store_true')
    parser.add_argument('--baseline-cpp', type=Path)
    arguments = parser.parse_args()
    libraries = build_oracles(root, arguments)
    report = {'created_at': datetime.now(timezone.utc).isoformat(), 'platform': platform.platform(),
              'reference_commit': subprocess.check_output(['git', '-C', str(arguments.reference), 'rev-parse', 'HEAD'], text=True).strip(),
              'binaries': {name: fingerprint(arguments.artifacts / (name + '.dylib')) for name in ['zig', 'cpp']},
              'nghttp2': fingerprint(arguments.nghttp2 / 'lib/libnghttp2.a'), 'cases': 0, 'failures': []}
    for fixture in cases():
        values = [evaluate(library, fixture) for library in libraries]
        report['cases'] += 1
        if values[0] != values[1]:
            data, response, fragment, fail_after = fixture
            report['failures'].append({'input': data.hex(), 'response': response, 'fragment': fragment,
                                       'fail_after': fail_after, 'zig': values[0][0], 'cpp': values[1][0],
                                       'zig_events': values[0][2].hex(), 'cpp_events': values[1][2].hex()})
            if len(report['failures']) == 10:
                break
    print(f"HTTP/2: {report['cases']} cases, {len(report['failures'])} differences", flush=True)
    if arguments.performance and not report['failures']:
        if arguments.baseline_cpp:
            report['baseline_cpp_sha256'] = fingerprint(arguments.baseline_cpp)
            report['paired_cpp'] = measure([load_library(arguments.baseline_cpp), libraries[1]], 'previous_cpp')
        report['performance'] = measure(libraries)
    source_files = sources(root, arguments)
    report['sources'] = {str(path): fingerprint(path) for path in source_files}
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    if report['failures'] or any(not value['accepted'] for value in report.get('performance', {}).values()):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
