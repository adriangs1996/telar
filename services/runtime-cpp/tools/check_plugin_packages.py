#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import statistics
import tempfile
import time

import check_plugin_data as data


def write_manifest(root, manifest):
    (root / 'plugin.json').write_bytes(data.encoded(manifest))


def prepare(root, scenario):
    manifest = data.manifest()
    manifest['actions'] = ['inspect', 'notify']
    manifest['capabilities'] = ['notifications', 'proxy.tap', 'network']
    write_manifest(root, manifest)
    (root / 'main.lua').write_text('return {on_exchange=function() return nil end}\n')
    if scenario == 'nested':
        (root / 'nested').mkdir()
        (root / 'nested/empty').mkdir()
        (root / 'nested/helper.lua').write_text('return true')
        (root / '.hidden').write_bytes(b'\x00\xff')
    elif scenario == 'unicode':
        manifest['entry'] = 'café.lua'
        (root / 'main.lua').rename(root / manifest['entry'])
        (root / '日本語').write_text('contents')
        write_manifest(root, manifest)
    elif scenario == 'backslash':
        manifest['entry'] = 'sub\\main.lua'
        (root / 'main.lua').rename(root / manifest['entry'])
        write_manifest(root, manifest)
    elif scenario == 'missing-manifest':
        (root / 'plugin.json').unlink()
    elif scenario == 'missing-entry':
        (root / 'main.lua').unlink()
    elif scenario == 'entry-directory':
        (root / 'main.lua').unlink()
        (root / 'main.lua').mkdir()
    elif scenario == 'entry-nul':
        manifest['entry'] = 'main.lua\0suffix'
        write_manifest(root, manifest)
    elif scenario == 'manifest-symlink':
        (root / 'plugin.json').rename(root / 'manifest.json')
        (root / 'plugin.json').symlink_to('manifest.json')
    elif scenario == 'entry-symlink':
        (root / 'main.lua').rename(root / 'other.lua')
        (root / 'main.lua').symlink_to('other.lua')
    elif scenario == 'escaping-entry':
        (root / 'main.lua').unlink()
        (root / 'main.lua').symlink_to('/etc/passwd')
    elif scenario == 'helper-symlink':
        (root / 'helper.lua').symlink_to('main.lua')
    elif scenario == 'directory-symlink':
        (root / 'sub').symlink_to('/tmp', target_is_directory=True)
    elif scenario == 'fifo':
        os.mkfifo(root / 'pipe')
    elif scenario.startswith('entries-'):
        count = int(scenario.split('-')[1])
        for index in range(count - 2):
            (root / f'file-{index}').write_bytes(b'')
    elif scenario.startswith('directories-'):
        count = int(scenario.split('-')[1])
        for index in range(count - 2):
            (root / f'directory-{index}').mkdir()
    elif scenario.startswith('depth-'):
        count = int(scenario.split('-')[1])
        parent = root
        for _ in range(count):
            parent = parent / 'd'
            parent.mkdir()
        (parent / 'file').write_text('nested')
    elif scenario.startswith('manifest-bytes-'):
        count = int(scenario.removeprefix('manifest-bytes-'))
        source = (root / 'plugin.json').read_bytes()
        (root / 'plugin.json').write_bytes(source + b' ' * (count - len(source)))
    elif scenario.startswith('entry-bytes-'):
        count = int(scenario.removeprefix('entry-bytes-'))
        (root / 'main.lua').write_bytes(b'x' * count)
    elif scenario.startswith('total-bytes-'):
        count = int(scenario.removeprefix('total-bytes-'))
        existing = sum(path.stat().st_size for path in root.iterdir())
        (root / 'data').write_bytes(b'x' * (count - existing))
    elif scenario == 'root-symlink':
        alias = root.parent / 'alias'
        alias.symlink_to(root, target_is_directory=True)
        return alias
    return root


def main():
    parser = argparse.ArgumentParser(description='Compare package inspection and digest with Zig')
    parser.add_argument('--zig', type=pathlib.Path, required=True)
    parser.add_argument('--cpp', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--snapshot', action='store_true')
    parser.add_argument('--pairs', type=int, default=0)
    parser.add_argument('--iterations', type=int, default=50)
    arguments = parser.parse_args()
    binaries = {'zig': arguments.zig.resolve(), 'cpp': arguments.cpp.resolve()}
    report = {'snapshot': arguments.snapshot, 'binaries': {name: {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                           for name, path in binaries.items()}, 'cases': []}
    scenarios = ['basic', 'nested', 'unicode', 'backslash', 'missing-manifest', 'missing-entry',
                 'entry-directory', 'entry-nul', 'manifest-symlink', 'entry-symlink', 'escaping-entry',
                 'helper-symlink', 'directory-symlink', 'fifo', 'root-symlink']
    scenarios += [f'{kind}-{count}' for kind in ['entries', 'directories'] for count in [255, 256, 257]]
    scenarios += [f'depth-{count}' for count in [32, 128, 253, 254]]
    scenarios += [f'manifest-bytes-{count}' for count in [65535, 65536, 65537]]
    scenarios += [f'entry-bytes-{count}' for count in [0, 1048575, 1048576, 1048577]]
    scenarios += [f'total-bytes-{count}' for count in [16777215, 16777216, 16777217]]
    for scenario in scenarios:
        with tempfile.TemporaryDirectory(prefix='telar-plugin-package-') as directory:
            root = pathlib.Path(directory) / 'package'
            root.mkdir()
            selected = prepare(root, scenario)
            results = {}
            for language, binary in binaries.items():
                action = 'snapshot' if language == 'cpp' and arguments.snapshot else 'inspect'
                process = subprocess.run([str(binary), 'plugin', action, str(selected)],
                                         capture_output=True, timeout=15)
                results[language] = {'exit_code': process.returncode, 'output': process.stdout.hex(),
                                     'error': process.stderr.decode(errors='replace')}
            equivalent = ((results['zig']['exit_code'] == 0) == (results['cpp']['exit_code'] == 0)
                          and results['zig']['output'] == results['cpp']['output'])
            report['cases'].append({'name': scenario, 'equivalent': equivalent, 'results': results})
            arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    report['differences'] = sum(not case['equivalent'] for case in report['cases'])
    if not report['differences'] and arguments.pairs:
        report['measurements'] = benchmark(binaries, arguments.pairs, arguments.iterations)
    arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f"{len(report['cases'])} package cases, {report['differences']} differences")
    return int(bool(report['differences']))


def benchmark(binaries, pairs, iterations):
    measurements = {}
    for scenario in ['basic', 'entries-256', 'total-bytes-16777215']:
        with tempfile.TemporaryDirectory(prefix='telar-plugin-package-benchmark-') as directory:
            root = pathlib.Path(directory) / 'package'
            root.mkdir()
            prepare(root, scenario)
            commands = {name: [str(binary), 'plugin', 'inspect', str(root)] for name, binary in binaries.items()}
            expected = subprocess.run(commands['zig'], capture_output=True, check=True).stdout

            def measure(language, count):
                started = time.perf_counter_ns()
                for _ in range(count):
                    process = subprocess.run(commands[language], capture_output=True, check=True)
                    if process.stdout != expected:
                        raise RuntimeError(f'{scenario}: output changed during benchmark')
                return (time.perf_counter_ns() - started) / count

            for language in binaries:
                measure(language, 4)
            samples = []
            for index in range(pairs):
                order = ['zig', 'cpp'] if index % 2 == 0 else ['cpp', 'zig']
                sample = {language: measure(language, iterations) for language in order}
                sample['ratio'] = sample['cpp'] / sample['zig']
                samples.append(sample)
            measurements[scenario] = {'iterations': iterations, 'samples_ns': samples,
                                      'wins': sum(sample['ratio'] <= 1 for sample in samples),
                                      'median_ratio': statistics.median(sample['ratio'] for sample in samples)}
            print(scenario, measurements[scenario]['wins'], measurements[scenario]['median_ratio'], flush=True)
    return measurements


if __name__ == '__main__':
    raise SystemExit(main())
