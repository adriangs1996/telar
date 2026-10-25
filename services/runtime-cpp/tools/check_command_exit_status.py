#!/usr/bin/env python3
import argparse
import ctypes
import hashlib
import itertools
import json
from pathlib import Path
import random
import shutil
import subprocess


def cases():
    values = set()
    for length in range(6):
        values.update(''.join(chars) for chars in itertools.product('01_+-;x', repeat=length))
    for value in range(-2147483652, -2147483643):
        values.add(str(value))
    for value in range(2147483643, 2147483652):
        values.add(str(value))
    for value in ['2147483647', '-2147483648', '+2147483647', '2147483648', '-2147483649', '00000000000000000001']:
        for separator in ['_', '__', '___']:
            values.add(separator.join(value))
            if value.startswith(('+', '-')):
                values.add(value[0] + separator.join(value[1:]))
        values.add(value + ';ignored')
    randomizer = random.Random(133)
    for _ in range(10000):
        values.add(''.join(randomizer.choices('0123456789_+-;x \t\x00', k=randomizer.randrange(1, 48))))
    values.add('0' * 4000 + '1')
    values.add('-' + '0' * 4000)
    return sorted(values)


def main():
    parser = argparse.ArgumentParser(description='Compare OSC 133 completion status parsing against the unchanged Zig parser')
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    artifacts = arguments.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(arguments.reference / 'lib/cmdcapture/osc.zig', artifacts / 'osc.zig')
    (artifacts / 'reference.zig').write_text('const std = @import("std");\nconst osc = @import("osc.zig");\npub export fn command_exit_status(input: [*]const u8, length: usize) i64 {\n    return if (osc.parseExitCode(input[0..length])) |value| value else std.math.minInt(i64);\n}\n')
    commands = [
        ['/opt/homebrew/bin/zig', 'build-lib', '-dynamic', '-O', 'ReleaseFast', '-lc', str(artifacts / 'reference.zig'), '-femit-bin=' + str(artifacts / 'zig.dylib')],
        ['/opt/homebrew/opt/llvm/bin/clang++', '-std=c++23', '-O3', '-dynamiclib', '-I' + str(root), '-I' + str(root.parent / 'desktop-mode'), str(root / 'tests/command_exit_status.cpp'), '-o', str(artifacts / 'cpp.dylib')],
    ]
    for index, command in enumerate(commands):
        with (artifacts / f'build-{index}.log').open('w') as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    functions = {}
    for language in ['zig', 'cpp']:
        function = ctypes.CDLL(str(artifacts / f'{language}.dylib')).command_exit_status
        function.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        function.restype = ctypes.c_int64
        functions[language] = function
    report = {'build_commands': commands, 'cases': 0, 'differences': [], 'binaries': {}}
    for language in functions:
        binary = artifacts / f'{language}.dylib'
        report['binaries'][language] = {'path': str(binary), 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    for value in cases():
        encoded = value.encode()
        results = {language: function(encoded, len(encoded)) for language, function in functions.items()}
        report['cases'] += 1
        if results['zig'] != results['cpp']:
            report['differences'].append({'input': value, 'results': results})
    arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    print(report['cases'], 'cases,', len(report['differences']), 'differences')
    return int(bool(report['differences']))


if __name__ == '__main__':
    raise SystemExit(main())
