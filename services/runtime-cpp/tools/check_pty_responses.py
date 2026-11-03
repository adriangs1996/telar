#!/usr/bin/env python3
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import random
import subprocess


class Operation(ctypes.Structure):
    _fields_ = [('kind', ctypes.c_uint32), ('bytes', ctypes.c_char_p), ('length', ctypes.c_size_t)]


def fixtures():
    yield [(0, b'')] * 66 + [(1, b'')] * 66
    yield [(0, b'x' * size) for size in [0, 1, 1023, 1024, 1025, 65536]] + [(1, b'')] * 6
    yield [(0, bytes([index]) * 1024) for index in range(66)] + [(1, b'')] * 64
    yield ([(0, b'a')] * 64 + [(1, b'')] * 32 + [(0, b'b')] * 34 + [(1, b'')] * 64) * 3
    yield [(0, b'a')] * 65 + [(2, b''), (0, b'b'), (1, b'')]
    randomizer = random.Random(0x505459)
    for _ in range(1000):
        operations = []
        for _ in range(randomizer.randrange(1, 300)):
            kind = randomizer.choices([0, 1, 2], weights=[75, 24, 1])[0]
            size = randomizer.choice([0, 1, 7, 1023, 1024, 1025, 4096]) if kind == 0 else 0
            operations.append((kind, randomizer.randbytes(size)))
        yield operations


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compiler', default='clang++')
    parser.add_argument('--zig', default='zig')
    arguments = parser.parse_args()
    artifacts = arguments.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=False)
    reference_commit = '23c87dfcb14d0a0524808c4ca46c3d9d17056ad1'
    for name in ['pane/PtyResponseQueue.zig', 'pane/pane_namespace.zig', 'pane/ScreenResize.zig', 'media/ParkingMutex.zig']:
        destination = artifacts / 'reference' / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(subprocess.check_output(['git', 'show', reference_commit + ':src/backend/' + name], cwd=root))
    (artifacts / 'oracle.zig').write_bytes((root / 'tests/pty_response_reference.zig').read_bytes())
    subprocess.run([arguments.zig, 'build-lib', '-dynamic', '-O', 'ReleaseFast', '-lc', str(artifacts / 'oracle.zig'), '-femit-bin=' + str(artifacts / 'zig.dylib')], check=True)
    subprocess.run([arguments.compiler, '-std=c++23', '-O3', '-dynamiclib', '-I', str(root), '-I', str(root.parents[1] / 'dlls/telar-client/include'), '-I', str(root.parents[1] / 'dlls/telar-base/include'), '-I', str(root.parents[1] / 'dlls/telar-lua/include'), '-I', str(root.parents[1] / 'dlls/telar-platform/include'), '-I', str(root.parents[1] / 'dlls/telar-plugins/include'), '-I', str(root.parents[1] / 'dlls/telar-config/include'), str(root / 'tests/pty_response_oracle.cpp'), '-o', str(artifacts / 'cpp.dylib')], check=True)
    libraries = []
    for name in ['zig', 'cpp']:
        library = ctypes.CDLL(str(artifacts / (name + '.dylib')))
        library.evaluate.argtypes = [ctypes.POINTER(Operation), ctypes.c_size_t, ctypes.c_void_p]
        library.evaluate.restype = ctypes.c_size_t
        libraries.append(library)
    report = {'reference_commit': reference_commit, 'binaries': {name: hashlib.sha256((artifacts / (name + '.dylib')).read_bytes()).hexdigest() for name in ['zig', 'cpp']}, 'cases': 0, 'operations': 0, 'passed': False}
    digest = hashlib.sha256()
    for index, case in enumerate(fixtures()):
        operations = (Operation * len(case))(*(Operation(kind, data, len(data)) for kind, data in case))
        results = []
        for library in libraries:
            output = ctypes.create_string_buffer(len(case) * 1037)
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
