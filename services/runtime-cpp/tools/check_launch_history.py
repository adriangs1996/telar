#!/usr/bin/env python3
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess


def main():
    parser = argparse.ArgumentParser(description='Compare launch failure persistence with the unchanged Zig history store')
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    artifacts = arguments.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=False)
    for relative, name in [('src/backend/history', 'history'), ('src/core', 'core'), ('lib/sqlite', 'sqlite')]:
        shutil.copytree(arguments.reference / relative, artifacts / name)
    shutil.copyfile(root / 'tests/launch_history_reference.zig', artifacts / 'reference.zig')
    commands = [
        ['/opt/homebrew/bin/zig', 'build-lib', '-dynamic', '-O', 'ReleaseFast', '-lc', '-lsqlite3',
         '--dep', 'telar-core', '--dep', 'sqlite', '-Mroot=' + str(artifacts / 'reference.zig'),
         '-Mtelar-core=' + str(artifacts / 'core/core.zig'), '-Msqlite=' + str(artifacts / 'sqlite/root.zig'),
         '-femit-bin=' + str(artifacts / 'zig.dylib')],
        ['/opt/homebrew/opt/llvm/bin/clang++', '-std=c++23', '-O3', '-dynamiclib', '-DTELAR_DEBUG=0',
         '-I' + str(root), '-I' + str(root.parent / 'desktop-mode'),
         str(root / 'tests/launch_history_oracle.cpp'), str(root / 'history/database.cpp'),
         '-lsqlite3', '-o', str(artifacts / 'cpp.dylib')],
    ]
    for index, command in enumerate(commands):
        with (artifacts / f'build-{index}.log').open('w') as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    functions = {}
    report = {'build_commands': commands, 'cases': 0, 'differences': [], 'binaries': {}}
    for language in ['zig', 'cpp']:
        binary = artifacts / f'{language}.dylib'
        function = ctypes.CDLL(str(binary)).record_launch_failure
        function.argtypes = [ctypes.c_char_p, ctypes.c_uint32]
        function.restype = ctypes.c_int
        functions[language] = function
        report['binaries'][language] = {'path': str(binary), 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    for seed in [*range(96), *range(96), 96]:
        outcomes = {language: function(str(artifacts / f'{language}.sqlite').encode(), seed)
                    for language, function in functions.items()}
        report['cases'] += 1
        if outcomes['zig'] != outcomes['cpp']:
            report['differences'].append({'seed': seed, 'outcomes': outcomes})
    rows = {}
    for language in functions:
        with sqlite3.connect(artifacts / f'{language}.sqlite') as database:
            rows[language] = database.execute('SELECT * FROM launch_attempt ORDER BY id').fetchall()
            if database.execute('SELECT COUNT(*) FROM session').fetchone()[0] != 0:
                report['differences'].append({'unexpected_sessions': language})
    if rows['zig'] != rows['cpp']:
        report['differences'].append({'rows': rows})
    report['persisted_rows'] = len(rows['zig'])
    report['rows_sha256'] = {language: hashlib.sha256(json.dumps(values).encode()).hexdigest()
                             for language, values in rows.items()}
    arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    print(report['cases'], 'cases,', report['persisted_rows'], 'rows,', len(report['differences']), 'differences')
    return int(bool(report['differences']))


if __name__ == '__main__':
    raise SystemExit(main())
