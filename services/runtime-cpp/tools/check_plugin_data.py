#!/usr/bin/env python3
import argparse
import copy
import ctypes
import decimal
import hashlib
import json
import pathlib
import random
import shutil
import subprocess


def manifest():
    return {'api_version': 1, 'id': 'sample.plugin', 'version': '1.2.3', 'entry': 'main.lua',
            'source': {'url': 'https://example.test/plugin', 'revision': 'abc123'}}


def encoded(value):
    return json.dumps(value, separators=(',', ':')).encode()


def cases():
    base = manifest()
    yield 0, encoded(base)
    for field, values in {
        'api_version': [None, False, True, 0, 2, 65536, -1, 1.0, '1', '01', '+1', '1_0', '0_1',
                        '1.0', '1e0', '10e-1', '0x1', '1.0000000000000000000000000000001', ' 1', '1 '],
        'id': ['', '.', '.a', 'a.', 'a..b', 'a/b', 'a_b-2.x', 'é', 'a'*64, 'a'*65, 'a\0b'],
        'version': ['', 'v'*32, 'v'*33, None, 1, '\0'],
        'entry': ['', '/main.lua', '.', '..', 'a/../b', 'a//b', 'a\\..\\b', 'a\\b', 'a'*256, 'a'*257, 'a\0b'],
        'source': [{}, {'url': '', 'revision': 'a'}, {'url': 'a', 'revision': ''},
                   {'url': 'a', 'revision': 'b', 'extra': 1}, {'url': 'é', 'revision': 'é'}],
        'actions': [None, {}, [], ['a'], ['a', 'a'], ['a..b'], ['x'*64], ['x'*65], list(map(str, range(64))), list(map(str, range(65)))],
        'capabilities': [None, {}, [], ['proxy.tap'], ['proxy.tap', 'notifications'], ['proxy.tap', 'proxy.tap'], ['unknown']],
    }.items():
        for value in values:
            variant = copy.deepcopy(base)
            variant[field] = value
            yield 0, encoded(variant)
    for key in list(base):
        variant = copy.deepcopy(base)
        del variant[key]
        yield 0, encoded(variant)
    yield 0, encoded(base)[:-1] + b',"id":"other"}'
    yield 0, encoded(base).replace(b'"id":', b'"i\\u0064":')
    yield 0, encoded(base)[:-1] + b',"i\\u0064":"other"}'
    yield 0, encoded(base) + b'\n'
    yield 0, encoded(base) + b' trailing'
    yield 0, encoded(base) + b' ' * 65536
    versions = ['1.', '.1e1', '1_0e-1', '0__1', '0__1.0', '1._0', '1.0_',
                '0x1.0p0', '0X1.p+0', '0x.8p1', '0x1p0', '0x1e', '0x0_1.p0']
    with decimal.localcontext() as context:
        context.prec = 180
        one = decimal.Decimal(1)
        for power in range(1, 151):
            for sign in [-1, 1]:
                versions.append(format(one + sign * decimal.Decimal(10)**-power, 'f'))
                versions.append(f'0x{(1 << power) + sign:x}.0p-{power}')
        for boundary in [one - decimal.Decimal(2)**-114, one + decimal.Decimal(2)**-113]:
            for delta in [-1, 0, 1]:
                versions.append(format(boundary + delta * decimal.Decimal(10)**-150, 'f'))
    for version in versions:
        yield 0, encoded(dict(base, api_version=version))

    grant = {'plugin': 'sample.plugin', 'digest': 'ab' * 32, 'capabilities': ['proxy.tap', 'notifications']}
    trust = {'version': 1, 'grants': [grant]}
    yield 1, encoded(trust)
    for version in [1, 1.0, '1', '1.0', '10e-1', True, None, 2]:
        yield 1, encoded({'version': version, 'grants': []})
    for count in [0, 1, 64, 65]:
        yield 1, encoded({'version': 1, 'grants': [dict(grant, plugin=f'plugin.{index}') for index in range(count)]})
    for field, values in {
        'plugin': ['', '.', 'a..b', 'x'*64, 'x'*65, 'é'],
        'digest': ['AB'*32, '', 'ab'*31, 'ab'*33, 'zz'*32, '0x'+'ab'*31, 'é'*64, 0],
        'capabilities': [[], {}, None, ['proxy.tap', 'proxy.tap'], ['unknown']],
    }.items():
        for value in values:
            yield 1, encoded({'version': 1, 'grants': [dict(grant, **{field: value})]})
    yield 1, encoded({'version': 1, 'grants': [grant, grant]})
    for mode, valid in [(0, encoded(base)), (1, encoded(trust))]:
        for length in range(len(valid)):
            yield mode, valid[:length]
        generator = random.Random(873)
        for _ in range(1500):
            damaged = bytearray(valid)
            damaged[generator.randrange(len(damaged))] = generator.randrange(256)
            yield mode, bytes(damaged)


def load(path):
    library = ctypes.CDLL(str(path))
    function = library.plugin_data
    function.argtypes = [ctypes.c_uint, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
    function.restype = ctypes.c_size_t
    return function


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--artifacts', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--compiler', default='/opt/homebrew/opt/llvm/bin/clang++')
    parser.add_argument('--zig', default='/opt/homebrew/bin/zig')
    arguments = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    artifacts = arguments.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=False)
    shutil.copytree(root.parents[1] / 'src/core', artifacts / 'core')
    shutil.copyfile(root / 'tests/plugin_data_reference.zig', artifacts / 'oracle.zig')
    commands = {
        'zig': [arguments.zig, 'build-lib', '-dynamic', '-O', 'ReleaseFast', '-lc', '--dep', 'telar-core',
                '-Mroot=' + str(artifacts / 'oracle.zig'), '-Mtelar-core=' + str(artifacts / 'core/core.zig'),
                '-femit-bin=' + str(artifacts / 'zig.dylib')],
        'cpp': [arguments.compiler, '-std=c++23', '-O3', '-dynamiclib', '-I', str(root), '-I', str(root.parent / 'desktop-mode'),
                str(root / 'tests/plugin_data.cpp'), '-o', str(artifacts / 'cpp.dylib')],
    }
    for language, command in commands.items():
        with (artifacts / f'{language}-build.log').open('w') as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    functions = {language: load(artifacts / f'{language}.dylib') for language in commands}
    output = ctypes.create_string_buffer(65536)
    mismatches = []
    count = 0
    for mode, source in cases():
        count += 1
        results = {}
        for language, function in functions.items():
            size = function(mode, source, len(source), output, len(output))
            results[language] = output.raw[:size].hex()
        if results['zig'] != results['cpp']:
            mismatches.append({'mode': mode, 'input': source.hex(), 'results': results})
    report = {'case_count': count, 'differences': mismatches, 'commands': commands,
              'binaries': {language: hashlib.sha256((artifacts / f'{language}.dylib').read_bytes()).hexdigest()
                           for language in commands},
              'sources': {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                          for directory in [root / 'plugins', root / 'text', artifacts / 'core']
                          for path in directory.glob('*') if path.is_file()}}
    arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'{count} cases, {len(mismatches)} differences')
    return int(bool(mismatches))


if __name__ == '__main__':
    raise SystemExit(main())
