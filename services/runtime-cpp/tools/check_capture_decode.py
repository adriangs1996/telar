#!/usr/bin/env python3
import argparse
import ctypes
import faulthandler
from datetime import datetime, timezone
import gzip
import hashlib
import json
import multiprocessing
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import time
import zlib


class Input(ctypes.Structure):
    _fields_ = [('bytes', ctypes.c_char_p), ('length', ctypes.c_size_t), ('encoding', ctypes.c_char_p),
                ('encoding_length', ctypes.c_size_t), ('limit', ctypes.c_size_t), ('output', ctypes.c_void_p)]


class Result(ctypes.Structure):
    _fields_ = [('length', ctypes.c_size_t), ('decoded', ctypes.c_uint8), ('truncated', ctypes.c_uint8),
                ('failed', ctypes.c_uint8), ('error', ctypes.c_uint8)]


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_library(path):
    library = ctypes.CDLL(str(path))
    library.decode.argtypes = [ctypes.POINTER(Input), ctypes.POINTER(Result)]
    library.decode.restype = None
    library.batch.argtypes = [ctypes.POINTER(Input), ctypes.c_size_t]
    library.batch.restype = ctypes.c_uint64
    return library


def build(root, arguments):
    directory = arguments.artifacts.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    shutil.copytree(arguments.reference / 'lib/exchangecapture', directory / 'reference')
    shutil.copyfile(root / 'tests/capture_decode_reference.zig', directory / 'oracle.zig')
    brotli = arguments.brotli.resolve()
    zstd = arguments.zstd.resolve()
    brotli_libraries = [str(brotli / 'lib' / name) for name in ['libbrotlidec.a', 'libbrotlicommon.a']]
    subprocess.run([arguments.zig, 'build-lib', '-dynamic', '-O', 'ReleaseFast', '-lc', *brotli_libraries,
                    '--dep', 'capture', '-Mroot=' + str(directory / 'oracle.zig'),
                    '--dep', 'cblocks', '-I', str(brotli / 'include'), '-Mcapture=' + str(directory / 'reference/root.zig'),
                    '-Mcblocks=' + str(arguments.reference.resolve() / 'lib/cblocks/root.zig'),
                    '-femit-bin=' + str(directory / 'zig.dylib')], check=True)
    subprocess.run([arguments.compiler, '-std=c++23', '-O3', '-dynamiclib', '-I', str(root), '-I', str(root.parents[1] / 'dlls/telar-client/include'), '-I', str(root.parents[1] / 'dlls/telar-base/include'), '-I', str(root.parents[1] / 'dlls/telar-lua/include'), '-I', str(root.parents[1] / 'dlls/telar-platform/include'), '-I', str(root.parents[1] / 'dlls/telar-plugins/include'), '-I', str(root.parents[1] / 'dlls/telar-config/include'),
                    '-I', str(brotli / 'include'), '-I', str(zstd / 'include'),
                    str(root / 'tests/capture_decode.cpp'), '-lz', *brotli_libraries,
                    str(zstd / 'lib/libzstd.a'), '-o', str(directory / 'cpp.dylib')], check=True)
    return [load_library(directory / name) for name in ['zig.dylib', 'cpp.dylib']]


class Encoders:
    def __init__(self, arguments):
        self.brotli = ctypes.CDLL(str(arguments.brotli / 'lib/libbrotlienc.dylib'))
        self.brotli.BrotliEncoderMaxCompressedSize.argtypes = [ctypes.c_size_t]
        self.brotli.BrotliEncoderMaxCompressedSize.restype = ctypes.c_size_t
        self.brotli.BrotliEncoderCompress.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_size_t,
                                                     ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p]
        self.brotli.BrotliEncoderCompress.restype = ctypes.c_int
        self.zstd = ctypes.CDLL(str(arguments.zstd / 'lib/libzstd.dylib'))
        self.zstd.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
        self.zstd.ZSTD_compressBound.restype = ctypes.c_size_t
        self.zstd.ZSTD_compress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
        self.zstd.ZSTD_compress.restype = ctypes.c_size_t
        self.zstd.ZSTD_isError.argtypes = [ctypes.c_size_t]
        self.zstd.ZSTD_isError.restype = ctypes.c_uint

    def encode(self, data, coding):
        if coding == b'gzip':
            return gzip.compress(data, mtime=0)
        if coding == b'deflate':
            return zlib.compress(data)
        if coding == b'br':
            size = ctypes.c_size_t(self.brotli.BrotliEncoderMaxCompressedSize(len(data)))
            output = ctypes.create_string_buffer(size.value)
            if not self.brotli.BrotliEncoderCompress(5, 22, 0, len(data), data, ctypes.byref(size), output):
                raise RuntimeError('Brotli fixture compression failed')
            return output.raw[:size.value]
        capacity = self.zstd.ZSTD_compressBound(len(data))
        output = ctypes.create_string_buffer(capacity)
        size = self.zstd.ZSTD_compress(output, capacity, data, len(data), 3)
        if self.zstd.ZSTD_isError(size):
            raise RuntimeError('Zstd fixture compression failed')
        return output.raw[:size]


def fixtures(encoders):
    randomizer = random.Random(0x4445434F4445)
    bodies = [b'', b'x', b'hello world', b'abcd' * 1000, randomizer.randbytes(4096), b'x' * (256 * 1024)]
    corpus = []
    for coding in [b'gzip', b'deflate', b'br', b'zstd']:
        for body in bodies:
            encoded = encoders.encode(body, coding)
            limits = sorted({0, 1, 2, 7, 31, 1024, max(1, len(body) - 1), len(body), len(body) + 1})
            for limit in limits:
                yield encoded, coding, limit
                yield encoded + b'garbage', coding, limit
                yield encoded + encoded, coding, limit
            for length in sorted({0, 1, 2, len(encoded) // 2, max(0, len(encoded) - 8), len(encoded) - 1}):
                for limit in [1, 64, len(body) + 1]:
                    yield encoded[:length], coding, limit
            corpus.append((encoded, coding, len(body)))

    for encoding in [b'', b'identity', b'IDENTITY', b' identity ', b'identity, identity', b'gzip,', b',gzip',
                     b'identity, identity, identity', b'unknown', b'unknown, identity', b'gzip;foo', b'\tidentity\t']:
        for limit in [1, 7, 100]:
            yield b'raw bytes', encoding, limit

    for first in [b'gzip', b'deflate', b'br', b'zstd', b'identity', b'unknown']:
        for second in [b'gzip', b'deflate', b'br', b'zstd', b'identity']:
            body = b'chain contents ' * 50
            inside = body if first in [b'identity', b'unknown'] else encoders.encode(body, first)
            encoded = inside if second == b'identity' else encoders.encode(inside, second)
            for limit in [1, 31, 750, 1024]:
                yield encoded, first + b', ' + second, limit

    for length in [1, 31, 32, 200, 4095, 4096]:
        body = b'L' * length
        literal_header = bytes([length << 3]) if length < 32 else ((length << 4) | (4 if length < 4096 else 12)).to_bytes(2 if length < 4096 else 3, 'little')
        block = literal_header + body + b'\0'
        frame = bytes.fromhex('28b52ffd8038') + length.to_bytes(4, 'little') + ((len(block) << 3) | 5).to_bytes(3, 'little') + block
        prefix = encoders.encode(b'x' * 131072, b'zstd')
        for limit in [1, length, 131072, 131073, 131072 + length, 262144]:
            yield frame, b'zstd', limit
            yield prefix + frame, b'zstd', limit
            yield prefix + frame[:-1], b'zstd', limit

    for tag in range(16):
        frame = (0x184D2A50 + tag).to_bytes(4, 'little') + (4).to_bytes(4, 'little') + b'skip'
        for length in range(len(frame) + 1):
            yield frame[:length], b'zstd', 1

    for body_size in [0, 1, 12, 127, 255]:
        for declared_size in [0, 1, 12, 31, 127, 255]:
            frame = bytes.fromhex('28b52ffd20') + bytes([declared_size]) + ((body_size << 3) | 1).to_bytes(3, 'little') + b'x' * body_size
            for limit in [1, 12, 64, 1024, 131071, 131072, 131073]:
                yield frame, b'zstd', limit

    for index in range(2000):
        encoded, coding, length = randomizer.choice(corpus)
        mutated = bytearray(encoded)
        for _ in range(randomizer.randrange(1, 4)):
            position = randomizer.randrange(len(mutated))
            mutated[position] = randomizer.randrange(256)
        if index % 3 == 0:
            mutated = mutated[:randomizer.randrange(len(mutated) + 1)]
        yield bytes(mutated), coding, randomizer.choice([1, 16, 1024, length + 1])


def request(case):
    data, encoding, limit = case
    output = ctypes.create_string_buffer(max(1, limit))
    value = Input(data, len(data), encoding, len(encoding), limit, ctypes.addressof(output))
    return value, output


def evaluate(library, case):
    value, output = request(case)
    result = Result()
    library.decode(ctypes.byref(value), ctypes.byref(result))
    return tuple(getattr(result, name) for name, _ in Result._fields_), output.raw[:result.length]


def decode_worker(path, connection, diagnostic):
    with open(diagnostic, 'a') as log:
        faulthandler.enable(file=log)
        library = load_library(Path(path))
        while True:
            case = connection.recv()
            if case is None:
                return
            connection.send(evaluate(library, case))


class IsolatedDecoder:
    def __init__(self, path):
        self.path = path
        self.process = None
        self.connection = None
        self.failure = None

    def evaluate(self, case):
        if self.process is None:
            context = multiprocessing.get_context('spawn')
            self.connection, child = context.Pipe()
            self.process = context.Process(target=decode_worker, args=(str(self.path), child, str(self.path.with_suffix('.crashes.log'))))
            self.process.start()
            child.close()
        try:
            self.connection.send(case)
            if not self.connection.poll(10):
                self.process.kill()
                self.process.join()
                self.failure = 'timeout'
            else:
                return self.connection.recv()
        except (EOFError, BrokenPipeError, ConnectionResetError):
            self.process.join()
            self.failure = self.process.exitcode
        self.connection.close()
        self.process = None
        return None

    def close(self):
        if self.process is not None:
            self.connection.send(None)
            self.process.join(10)
            if self.process.is_alive():
                self.process.kill()
                self.process.join()
            self.connection.close()
            self.process = None


def measure(libraries, encoders):
    report = {}
    for coding in [b'gzip', b'deflate', b'br', b'zstd']:
        for length in [1024, 256 * 1024]:
            body = (b'{"message":"capture response"}\n' * (length // 31 + 1))[:length]
            case = encoders.encode(body, coding), coding, length + 1
            if evaluate(libraries[0], case) != evaluate(libraries[1], case):
                raise RuntimeError('Benchmark output mismatch')
            value, output = request(case)
            iterations = 2000 if length == 1024 else 200
            for library in libraries:
                library.batch(ctypes.byref(value), 50)
            pairs = []
            for pair in range(7):
                elapsed = {}
                checksums = []
                for index in ([0, 1] if pair % 2 == 0 else [1, 0]):
                    started = time.perf_counter_ns()
                    checksums.append(libraries[index].batch(ctypes.byref(value), iterations))
                    elapsed['zig' if index == 0 else 'cpp'] = (time.perf_counter_ns() - started) / iterations
                if checksums[0] != checksums[1]:
                    raise RuntimeError('Benchmark checksum mismatch')
                elapsed['ratio'] = elapsed['cpp'] / elapsed['zig']
                pairs.append(elapsed)
            name = coding.decode() + '-' + str(length)
            report[name] = {'iterations': iterations, 'pairs': pairs, 'wins': sum(pair['ratio'] <= 1 for pair in pairs),
                            'median_ratio': statistics.median(pair['ratio'] for pair in pairs)}
            print(name, report[name]['wins'], round(report[name]['median_ratio'], 3), flush=True)
    return report


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument('--reference', type=Path, default=root.parents[1])
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compiler', default='/opt/homebrew/opt/llvm/bin/clang++')
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--brotli', type=Path, default=Path('/opt/homebrew/opt/brotli'))
    parser.add_argument('--zstd', type=Path, default=Path('/opt/homebrew/opt/zstd'))
    parser.add_argument('--performance', action='store_true')
    parser.add_argument('--reuse-artifacts', action='store_true')
    arguments = parser.parse_args()
    report = {'measured_at': datetime.now(timezone.utc).isoformat(), 'platform': platform.platform(), 'cases': 0}
    baseline_worker = IsolatedDecoder(arguments.artifacts / 'zig.dylib')
    candidate_worker = IsolatedDecoder(arguments.artifacts / 'cpp.dylib')
    try:
        faulthandler.enable()
        libraries = [load_library(arguments.artifacts / (name + '.dylib')) for name in ['zig', 'cpp']] if arguments.reuse_artifacts else build(root, arguments)
        encoders = Encoders(arguments)
        report['binaries'] = {name: fingerprint(arguments.artifacts / (name + '.dylib')) for name in ['zig', 'cpp']}
        report['sources'] = {str(path.relative_to(root)): fingerprint(path) for path in sorted((root / 'exchange_capture').glob('*.hpp'))}
        digest = hashlib.sha256()
        for index, case in enumerate(fixtures(encoders)):
            (arguments.artifacts / 'current-case.json').write_text(json.dumps({'index': index, 'encoding': case[1].decode(), 'length': len(case[0]), 'limit': case[2]}) + '\n')
            baseline = baseline_worker.evaluate(case)
            candidate = candidate_worker.evaluate(case)
            if candidate is None:
                raise RuntimeError(f'C++ decoder crashed in case {index}: {candidate_worker.failure}')
            if baseline is None:
                diagnostic = {'index': index, 'input': case[0].hex(), 'encoding': case[1].decode(), 'limit': case[2],
                              'reference_failure': baseline_worker.failure, 'cpp': candidate[0]}
                (arguments.artifacts / f'reference-failure-{index}.json').write_text(json.dumps(diagnostic, indent=2) + '\n')
                report.setdefault('reference_failures', []).append({'index': index, 'failure': baseline_worker.failure, 'cpp': candidate[0]})
                continue
            if baseline != candidate:
                report['failed_case'] = {'index': index, 'input': case[0].hex(), 'encoding': case[1].decode(),
                                         'limit': case[2], 'zig': baseline[0], 'cpp': candidate[0]}
                for name, result in [('zig', baseline), ('cpp', candidate)]:
                    arguments.output.with_suffix('.' + name + '.bin').write_bytes(result[1])
                raise RuntimeError(f'Capture decode differs in case {index}')
            digest.update(baseline[1])
            report['cases'] += 1
        report['output_sha256'] = digest.hexdigest()
        baseline_worker.close()
        candidate_worker.close()
        print('Equivalent decode cases:', report['cases'], flush=True)
        if arguments.performance:
            report['performance'] = measure(libraries, encoders)
    except Exception as error:
        report['failure'] = str(error)
        raise
    finally:
        baseline_worker.close()
        candidate_worker.close()
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    if arguments.performance and any(case['wins'] < 6 for case in report['performance'].values()):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
