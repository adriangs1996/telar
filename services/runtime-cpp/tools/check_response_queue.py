#!/usr/bin/env python3
import argparse
import ctypes
import hashlib
import io
import json
from pathlib import Path
import random
import shutil
import subprocess
import tarfile


class Operation(ctypes.Structure):
    _fields_ = [('kind', ctypes.c_uint32), ('value', ctypes.c_uint64)]


def fixtures():
    yield [0] * 130 + [4, 5] + [2] * 129
    yield [0] * 127 + [5] + [2] * 130
    yield [1] * 127 + [0, 4, 5] + [2] * 130
    yield ([0, 1, 2] * 65 + [2] * 65) * 4
    yield [0] * 128 + [3, 5, 2, 2]
    randomizer = random.Random(0x525350)
    for _ in range(1000):
        yield randomizer.choices(range(6), weights=[30, 25, 25, 1, 10, 9], k=randomizer.randrange(1, 1000))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compiler', default='clang++')
    parser.add_argument('--zig', default='zig')
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    artifacts = arguments.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=False)
    reference = artifacts / 'reference'
    reference.mkdir()
    commit = '23c87dfcb14d0a0524808c4ca46c3d9d17056ad1'
    archive = subprocess.check_output(['git', 'archive', commit, 'src/backend', 'src/core', 'lib/keyinput', 'lib/fuzzymatch'], cwd=root.parents[1])
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(reference, filter='data')
    shutil.copyfile(root / 'tests/response_queue_reference.zig', reference / 'oracle.zig')
    command = [arguments.zig, 'build-lib', '-dynamic', '-O', 'ReleaseFast', '-lc', '--dep', 'telar-core', '--dep', 'fuzzymatch', '-Mroot=oracle.zig', '--dep', 'keyinput', '-Mtelar-core=src/core/core.zig', '-Mfuzzymatch=lib/fuzzymatch/root.zig', '-Mkeyinput=lib/keyinput/root.zig', '-femit-bin=' + str(artifacts / 'zig.dylib')]
    subprocess.run(command, cwd=reference, check=True)
    subprocess.run([arguments.compiler, '-std=c++23', '-O3', '-DTELAR_DEBUG=0', '-DTELAR_DIAGNOSTICS=0', '-dynamiclib', '-I', str(root), '-I', str(root.parents[1] / 'dlls/telar-client/include'), '-I', str(root.parents[1] / 'dlls/telar-base/include'), '-I', str(root.parents[1] / 'dlls/telar-lua/include'), '-I', str(root.parents[1] / 'dlls/telar-platform/include'), '-I', str(root.parents[1] / 'dlls/telar-plugins/include'), '-I', str(root.parents[1] / 'dlls/telar-config/include'), str(root / 'tests/response_queue_oracle.cpp'), '-o', str(artifacts / 'cpp.dylib')], check=True)
    libraries = []
    for name in ['zig', 'cpp']:
        library = ctypes.CDLL(str(artifacts / (name + '.dylib')))
        library.evaluate.argtypes = [ctypes.POINTER(Operation), ctypes.c_size_t, ctypes.c_void_p]
        library.evaluate.restype = ctypes.c_size_t
        libraries.append(library)
    report = {'reference_commit': commit, 'binaries': {name: hashlib.sha256((artifacts / (name + '.dylib')).read_bytes()).hexdigest() for name in ['zig', 'cpp']}, 'cases': 0, 'operations': 0, 'passed': False}
    digest = hashlib.sha256()
    for index, case in enumerate(fixtures()):
        operations = (Operation * len(case))(*(Operation(kind, position + 1) for position, kind in enumerate(case)))
        results = []
        for library in libraries:
            output = ctypes.create_string_buffer(len(case) * 21)
            length = library.evaluate(operations, len(case), output)
            results.append(output.raw[:length])
        if results[0] != results[1]:
            for name, result in zip(['zig', 'cpp'], results):
                (artifacts / f'failure-{index}-{name}.bin').write_bytes(result)
            report['failure'] = index
            arguments.output.write_text(json.dumps(report, indent=2) + '\n')
            raise RuntimeError(f'Queue mismatch at case {index}')
        digest.update(results[0])
        report['cases'] += 1
        report['operations'] += len(case)
    report.update(passed=True, output_sha256=digest.hexdigest())
    arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
