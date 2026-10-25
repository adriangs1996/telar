#!/usr/bin/env python3
import argparse
import ctypes
import hashlib
import io
import itertools
import json
from pathlib import Path
import random
import shutil
import subprocess
import tarfile


def fixtures():
    alphabet = b'aA_/'
    paths = [b'']
    for size in range(1, 6):
        paths.extend(bytes(value) for value in itertools.product(alphabet, repeat=size))
    for path in paths:
        for query in [b'', b'a', b'A', b'aa', b'Aa', b'/_', b'a/a', path, path + b'z']:
            yield path, query
    for length in [63, 64, 65, 1023, 1024, 1025, 4096]:
        for separator in [b'/', b'_', b'-', b' ', b'.', b'x', b'X']:
            for query in [b'abc', b'ABC', b'ab', b'c', b'aa', b'a' * 64, b'a' * 65]:
                yield b'x' * max(0, length - 4) + separator + b'aBc', query
                yield b'a' * length, query
    randomizer = random.Random(731)
    alphabet = b'aAbBcCdDeEfFgGhH0123456789/._- ' + 'café界'.encode()
    for index in range(12000):
        length = randomizer.randrange(1101)
        path = bytes(randomizer.choices(alphabet, k=length))
        if index % 3 == 0:
            positions = sorted(randomizer.sample(range(length), min(length, randomizer.randrange(65))))
            query = bytes(path[position] for position in positions)
        elif index % 3 == 1 and length <= 64:
            query = path
        else:
            query = bytes(randomizer.choices(alphabet, k=randomizer.randrange(70)))
        yield path, query


def main():
    parser = argparse.ArgumentParser(description='Compare fuzzy scores and highlight positions with the actual Zig matcher')
    parser.add_argument('--reference', default='23c87dfcb14d0a0524808c4ca46c3d9d17056ad1')
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    artifacts = arguments.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=False)
    archived = subprocess.run(['git', 'archive', arguments.reference, 'lib/fuzzymatch'], cwd=source.parents[1], check=True, capture_output=True).stdout
    with tarfile.open(fileobj=io.BytesIO(archived)) as archive:
        archive.extractall(artifacts, filter='data')
    shutil.copy2(source / 'tests/fuzzy_reference.zig', artifacts / 'reference.zig')
    commands = [
        ['/opt/homebrew/bin/zig', 'build-lib', '-dynamic', '-O', 'ReleaseFast', '-lc', str(artifacts / 'reference.zig'), '-femit-bin=' + str(artifacts / 'zig.dylib')],
        ['/opt/homebrew/opt/llvm/bin/clang++', '-std=c++23', '-O3', '-dynamiclib', '-DTELAR_DEBUG=0', '-I' + str(source), '-I' + str(source.parent / 'desktop-mode'), str(source / 'tests/fuzzy_oracle.cpp'), '-o', str(artifacts / 'cpp.dylib')],
    ]
    for index, command in enumerate(commands):
        with (artifacts / f'build-{index}.log').open('w') as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    functions = {}
    report = {'reference': arguments.reference, 'commands': commands, 'binaries': {}, 'cases': 0, 'differences': []}
    for language in ['zig', 'cpp']:
        binary = artifacts / f'{language}.dylib'
        function = ctypes.CDLL(str(binary)).fuzzy_score
        function.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_uint16)]
        function.restype = ctypes.c_uint64
        functions[language] = function
        report['binaries'][language] = {'path': str(binary), 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    for path, query in fixtures():
        results = {}
        for language, function in functions.items():
            positions = (ctypes.c_uint16 * max(1, len(query)))()
            score = function(path, len(path), query, len(query), positions)
            results[language] = (score, list(positions)[:len(query)] if score >> 32 == 1 else [])
        report['cases'] += 1
        if results['zig'] != results['cpp'] or any(value[0] >> 32 == 2 for value in results.values()):
            report['differences'].append({'path_hex': path.hex(), 'query_hex': query.hex(), 'results': results})
    report['passed'] = not report['differences']
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f"{report['cases']} cases, {len(report['differences'])} differences")
    return int(not report['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
