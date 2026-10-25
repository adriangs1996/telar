#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import shutil
import statistics
import struct
import subprocess
import tempfile
import time

import check_plugin_host as host


def build_reference(arguments, artifacts):
    root = pathlib.Path(__file__).resolve().parents[1]
    source = artifacts / 'reference'
    source.mkdir()
    for relative, name in [('src/backend/plugins', 'plugins'), ('src/backend/proxy', 'proxy'),
                           ('src/core', 'core'), ('lib/exchangecapture', 'exchangecapture')]:
        shutil.copytree(arguments.reference / relative, source / name)
    shutil.copyfile(root / 'tests/plugin_service_reference.zig', source / 'oracle.zig')
    (source / 'worker-executable.txt').write_text(str(arguments.zig_worker.resolve()))
    command = [arguments.zig, 'build-exe', '-O', 'ReleaseFast', '-lc',
               '--dep', 'telar-core', '--dep', 'exchangecapture', '-Mroot=' + str(source / 'oracle.zig'),
               '-Mtelar-core=' + str(source / 'core/core.zig'),
               '-Mexchangecapture=' + str(source / 'exchangecapture/root.zig'),
               '-femit-bin=' + str(artifacts / 'zig-service')]
    with (artifacts / 'zig-build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    return command


def cases():
    yield 'empty', host.plugin('return nil'), host.exchange(), 1
    yield 'state', 'local n=0; return {on_exchange=function(e) n=n+1; return {telar.effect.notification{title=n,message=e.id}} end}', host.exchange(), 100
    yield 'module', 'local v=require("helper"); return {on_exchange=function() return {telar.effect.notification{title=v}} end}', host.exchange(), 3
    yield 'sixteen', host.plugin('local r={}; for i=1,16 do r[i]=telar.effect.notification{title=i} end; return r'), host.exchange(), 1
    for level in ['info', 'success', 'warning', 'failure']:
        yield level, host.plugin(f'return {{telar.effect.notification{{title="a",message="b",level="{level}"}}}}'), host.exchange(), 1
    source = host.plugin('local h=e.request or e.response; return {telar.effect.notification{title=e.protocol,message=e.host..":"..e.method..":"..e.target..":"..e.status..":"..e.outcome..":"..#h.body..":"..tostring(e.generation)}}')
    for protocol in range(3):
        for present in [1, 2, 3]:
            for length in [0, 1, 1024, 65536, 262144]:
                yield f'exchange-{protocol}-{present}-{length}', source, host.exchange(protocol=protocol, present=present, body=b'x' * length), 1


def invoke(command, payload, count):
    try:
        completed = subprocess.run(command, input=host.framed(payload) * count, capture_output=True,
                                   env={}, cwd='/', timeout=15)
    except subprocess.TimeoutExpired as error:
        return {'exit_code': None, 'output': (error.stdout or b'').hex(),
                'error': (error.stderr or b'').decode(errors='replace'), 'timed_out': True}
    return {'exit_code': completed.returncode, 'output': completed.stdout.hex(),
            'error': completed.stderr.decode(errors='replace')}


def timed(command, payload, iterations):
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env={}, cwd='/') as process:
        sequence = 0

        def exchange():
            nonlocal sequence
            sequence += 1
            process.stdin.write(host.framed(payload))
            process.stdin.flush()
            length, = struct.unpack('<I', host.read_exact(process.stdout, 4))
            reply = host.read_exact(process.stdout, length)
            if reply[0] != 2 or struct.unpack_from('<Q', reply, 1)[0] != sequence:
                raise RuntimeError('Unexpected service event identity')
            return reply

        expected = exchange()[9:]
        for _ in range(64):
            if exchange()[9:] != expected:
                raise RuntimeError('Service warmup reply changed')
        checksum = hashlib.sha256()
        start = time.perf_counter_ns()
        for _ in range(iterations):
            reply = exchange()
            if reply[9:] != expected:
                raise RuntimeError('Service reply changed during timing')
            checksum.update(reply)
        elapsed = time.perf_counter_ns() - start
        process.stdin.close()
        process.wait(timeout=5)
        if process.returncode != 0:
            raise RuntimeError(process.stderr.read().decode(errors='replace'))
        return {'elapsed_ns': elapsed, 'checksum': checksum.hexdigest()}


def main():
    parser = argparse.ArgumentParser(description='Compare the real C++ and Zig plugin services and isolated workers')
    parser.add_argument('--reference', type=pathlib.Path, required=True)
    parser.add_argument('--zig-worker', type=pathlib.Path, required=True)
    parser.add_argument('--baseline-probe', type=pathlib.Path, help='Use a previous C++ service probe instead of building the Zig adapter')
    parser.add_argument('--cpp-worker', type=pathlib.Path, required=True)
    parser.add_argument('--cpp-probe', type=pathlib.Path, required=True)
    parser.add_argument('--artifacts', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--zig', default='/opt/homebrew/bin/zig')
    parser.add_argument('--pairs', type=int, default=7)
    parser.add_argument('--iterations', type=int, default=5000)
    parser.add_argument('--functional-only', action='store_true')
    arguments = parser.parse_args()
    artifacts = arguments.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=False)
    command = None
    if arguments.baseline_probe:
        shutil.copy2(arguments.baseline_probe, artifacts / 'zig-service')
    else:
        command = build_reference(arguments, artifacts)
    shutil.copyfile(arguments.cpp_probe, artifacts / 'cpp-service')
    shutil.copymode(arguments.cpp_probe, artifacts / 'cpp-service')
    shutil.copyfile(arguments.cpp_worker, artifacts / 'cpp-worker')
    shutil.copymode(arguments.cpp_worker, artifacts / 'cpp-worker')
    binaries = {'zig_service': artifacts / 'zig-service', 'zig_worker': arguments.zig_worker.resolve(),
                'cpp_service': artifacts / 'cpp-service', 'cpp_worker': artifacts / 'cpp-worker'}
    report = {'build_command': command, 'binaries': {name: {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                                                   for name, path in binaries.items()}, 'cases': [], 'benchmarks': {}}
    with tempfile.TemporaryDirectory(prefix='telar-plugin-service-') as temporary:
        directory = pathlib.Path(temporary).resolve()
        entry = directory / 'main.lua'
        (directory / 'helper.lua').write_text('return "helper"')
        commands = {language: [str(binaries[language + '_service']), str(entry), str(binaries[language + '_worker'])]
                    for language in ['zig', 'cpp']}
        for name, source, payload, count in cases():
            entry.write_text(source)
            results = {language: invoke(command, payload, count) for language, command in commands.items()}
            equal = results['zig']['exit_code'] == results['cpp']['exit_code'] == 0 and results['zig']['output'] == results['cpp']['output']
            report['cases'].append({'name': name, 'equivalent': equal, 'results': results})
            arguments.output.write_text(json.dumps(report, indent=2) + '\n')
        report['differences'] = sum(not case['equivalent'] for case in report['cases'])
        print(f"{len(report['cases'])} service cases, {report['differences']} differences", flush=True)
        if not report['differences'] and not arguments.functional_only:
            workloads = {
                'empty': (host.plugin('return nil'), host.exchange()),
                'notification': (host.plugin('return {telar.effect.notification{title="title",message="message"}}'), host.exchange()),
                'json': (host.plugin('local v=telar.json.decode(e.request.body); return {telar.effect.notification{title=v.value}}'), host.exchange()),
                'body-256k': (host.plugin('return {telar.effect.notification{title=#e.request.body}}'), host.exchange(body=b'x' * 262144)),
            }
            for name, (source, payload) in workloads.items():
                entry.write_text(source)
                samples = []
                for index in range(arguments.pairs):
                    order = ['zig', 'cpp'] if index % 2 == 0 else ['cpp', 'zig']
                    sample = {language: timed(commands[language], payload, arguments.iterations) for language in order}
                    if sample['zig']['checksum'] != sample['cpp']['checksum']:
                        raise RuntimeError('Paired service replies differ')
                    sample['ratio'] = sample['cpp']['elapsed_ns'] / sample['zig']['elapsed_ns']
                    samples.append(sample)
                    print(name, index + 1, sample['ratio'], flush=True)
                report['benchmarks'][name] = {'samples': samples, 'iterations': arguments.iterations,
                                              'wins': sum(sample['ratio'] <= 1 for sample in samples),
                                              'median_ratio': statistics.median(sample['ratio'] for sample in samples)}
                arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    return int(bool(report['differences']))


if __name__ == '__main__':
    raise SystemExit(main())
