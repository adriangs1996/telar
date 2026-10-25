#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import random
import statistics
import struct
import subprocess
import tempfile
import time


def sized(value):
    return struct.pack('<I', len(value)) + value


def framed(value):
    return sized(value)


def half(head, body, status=0, outcome=0):
    return (b'\x01' + sized(head) + sized(body) + sized(b'gzip') +
            struct.pack('<BBBHBq', 1, 0, 1, status, outcome, 123))


def exchange(protocol=1, present=3, body=b'{"value":4}', identity=21):
    head = b':method: POST\r\nx-value: one\r\nx-value: two\r\n'
    return (struct.pack('<BQQBQI', 1, identity, 8, protocol, 31, 5) +
            sized(b'example.test') + sized(b'POST') + sized(b'/resource') + struct.pack('<q', 100) +
            (half(head, body) if present & 1 else b'\x00') +
            (half(head, body, 503, 1) if present & 2 else b'\x00'))


def plugin(expression):
    return 'return {on_exchange = function(e) ' + expression + ' end}'


def cases():
    standard = exchange()
    for expression in [
        'nil', '{}', '{extra=true}', 'true', 'false', '42', '"failure"', '{{}}',
        '{telar.effect.notification{title="hello"}}',
        '{telar.effect.notification{title=73,message=123,duration_ms="100"}}',
        '{telar.effect.notification{title="binary\\0text",message="\\255"}}',
        '{telar.effect.notification{title=false}}',
        '{telar.effect.notification{title="x",level="invalid"}}',
        '{telar.effect.notification{title="x",duration_ms="invalid"}}',
        '{telar.effect.notification{title="x",duration_ms=1.5}}',
    ]:
        yield 'effect-' + expression, plugin('return ' + expression), framed(standard)
    for level in ['info', 'success', 'warning', 'failure', '']:
        for duration in [0, 4000, 4294967295, -1, 4294967296]:
            source = plugin(f'return {{telar.effect.notification{{title="x",level="{level}",duration_ms={duration}}}}}')
            yield f'level-{level}-{duration}', source, framed(standard)
    for count in [0, 1, 16, 17]:
        source = plugin(f'local effects={{}}; for i=1,{count} do effects[i]=telar.effect.notification{{title=i}} end; return effects')
        yield f'batch-{count}', source, framed(standard)
    for length in [1, 4095, 4096, 4097, 65536]:
        yield f'error-{length}', plugin(f'error(string.rep("x",{length}),0)'), framed(standard)
    for value in ['{}', 'true', '123', 'nil']:
        yield 'error-value-' + value, plugin(f'error({value},0)'), framed(standard)
    for expression in [
        'e.host="other"', 'e.request.body="other"', 'e.request.head.raw="other"',
        'e.request.head.fields[1]={}', 'e.request.head.fields[1].name="other"',
    ]:
        yield 'immutable-' + expression, plugin(expression), framed(standard)
    fields = ('id', 'host', 'protocol', 'connection_id', 'stream_id', 'method', 'target',
              'status', 'outcome', 'started_at_ms', 'finished_at_ms')
    expression = 'return {' + ','.join(f'telar.effect.notification{{title=tostring(e.{field})}}' for field in fields) + '}'
    for protocol in range(3):
        for present in [1, 2, 3]:
            for identity in [21, 2**63 - 1, 2**63, 2**64 - 1]:
                yield f'projection-{protocol}-{present}-{identity}', plugin(expression), framed(exchange(protocol, present, identity=identity))
    for body in [b'', b'\x00\xff', b'x' * 1024, b'x' * 65536, b'x' * 1048576]:
        source = plugin('return {telar.effect.notification{title=#e.request.body,message=e.request.body:sub(1,32)}}')
        yield f'body-{len(body)}', source, framed(exchange(body=body))
    for name in ['telar', 'helper', 'nilmodule', '65modules', '../helper', '.helper', 'helper.', 'helper..x', 'x/y', 'missing', 'escape', '123', 'true']:
        argument = name if name in ['123', 'true'] else json.dumps(name)
        source = plugin(f'local value=require({argument}); return {{telar.effect.notification{{title=type(value)}}}}')
        yield 'require-' + name, source, framed(standard)
    for value in ['"token=private"', '"ordinary text"', '123', 'true']:
        source = plugin('return {telar.effect.notification{title=telar.redact.secrets(' + value + ')}}')
        yield 'redact-' + value, source, framed(standard)
    for expression in [
        'while true do end', 'string.rep("x", 70*1024*1024)',
        'return {telar.effect.notification{title=string.rep("x",65536)}}',
    ]:
        source = 'local first=true; return {on_exchange=function(e) if first then first=false; ' + expression + ' end return nil end}'
        yield 'limit-' + expression, source, framed(standard) * 2
    source = 'local count=0; return {on_exchange=function() count=count+1; return {telar.effect.notification{title=count}} end}'
    yield 'stateful-100', source, framed(standard) * 100
    source = plugin('return nil')
    for length in range(len(standard)):
        yield f'truncated-payload-{length}', source, framed(standard[:length])
    for length in range(4):
        yield f'truncated-prefix-{length}', source, framed(standard)[:length]
    yield 'invalid-frame-size', source, struct.pack('<I', 128 * 1024 * 1024 + 1)
    generator = random.Random(1928)
    for index in range(200):
        altered = bytearray(standard)
        position = generator.randrange(len(altered))
        altered[position] = generator.randrange(256)
        yield f'mutated-{index}-{position}', source, framed(altered)


def execute(binary, entry, input_bytes):
    result = subprocess.run([str(binary), 'tap-worker', str(entry)], input=input_bytes,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12, env={}, cwd='/')
    return {'exit_code': result.returncode, 'stdout': result.stdout.hex(),
            'stderr': result.stderr.decode(errors='replace')}


def read_exact(stream, length):
    result = bytearray()
    while len(result) < length:
        chunk = stream.read(length - len(result))
        if not chunk:
            raise RuntimeError('Worker closed its reply pipe')
        result += chunk
    return bytes(result)


def timed(binary, entry, payload, iterations):
    with subprocess.Popen([str(binary), 'tap-worker', str(entry)], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={}, cwd='/') as process:
        def invoke():
            process.stdin.write(payload)
            process.stdin.flush()
            length, = struct.unpack('<I', read_exact(process.stdout, 4))
            return read_exact(process.stdout, length)

        expected = invoke()
        for _ in range(64):
            if invoke() != expected:
                raise RuntimeError('Worker warmup reply changed')
        start = time.perf_counter_ns()
        digest = hashlib.sha256()
        for _ in range(iterations):
            result = invoke()
            if result != expected:
                raise RuntimeError('Worker reply changed during timing')
            digest.update(result)
        elapsed = time.perf_counter_ns() - start
        process.stdin.close()
        process.wait(timeout=5)
        if process.returncode != 0:
            raise RuntimeError(process.stderr.read().decode(errors='replace'))
        return {'elapsed_ns': elapsed, 'checksum': digest.hexdigest()}


def main():
    parser = argparse.ArgumentParser(description='Compare isolated Lua tap workers with the Zig runtime')
    parser.add_argument('--zig', type=pathlib.Path, required=True)
    parser.add_argument('--cpp', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--pairs', type=int, default=7)
    parser.add_argument('--iterations', type=int, default=5000)
    parser.add_argument('--functional-only', action='store_true')
    parser.add_argument('--functional-report', type=pathlib.Path)
    arguments = parser.parse_args()
    source_root = pathlib.Path(__file__).resolve().parents[1]
    binaries = {'zig': arguments.zig.resolve(), 'cpp': arguments.cpp.resolve()}
    report = {'binaries': {name: {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                           for name, path in binaries.items()}, 'cases': [], 'benchmarks': {},
              'sources': {str(path.relative_to(source_root)): hashlib.sha256(path.read_bytes()).hexdigest()
                          for folder in ['plugins', 'lua', 'memory', 'platform']
                          for path in (source_root / folder).glob('*.hpp')}}
    report['sources']['tools/check_plugin_host.py'] = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
    if arguments.functional_report:
        previous = json.loads(arguments.functional_report.read_text())
        if previous['binaries'] != report['binaries'] or previous['differences']:
            raise RuntimeError('Functional report does not certify these binaries')
        report['cases'] = previous['cases']
        report['functional_report'] = str(arguments.functional_report.resolve())
    arguments.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        arguments.output.write_text(json.dumps(report, indent=2) + '\n')

    with tempfile.TemporaryDirectory(prefix='telar-plugin-oracle-') as directory:
        root = pathlib.Path(directory).resolve()
        entry = root / 'main.lua'
        (root / 'helper.lua').write_text('return {}')
        (root / 'nilmodule.lua').write_text('return nil')
        (root / '65modules.lua').write_text('for i=1,65 do assert(require("module"..i) == true) end return nil')
        for index in range(1, 66):
            (root / f'module{index}.lua').write_text('return nil')
        (root / 'escape.lua').symlink_to('/etc/passwd')
        for name, source, payload in (() if arguments.functional_report else cases()):
            entry.write_text(source)
            results = {language: execute(binary, entry, payload) for language, binary in binaries.items()}
            same = (results['zig']['exit_code'] == 0) == (results['cpp']['exit_code'] == 0)
            same = same and results['zig']['stdout'] == results['cpp']['stdout']
            reference_crash = results['zig']['exit_code'] < 0 and results['cpp']['exit_code'] >= 0
            row = {'name': name, 'equivalent': same, 'reference_crash': reference_crash}
            if not same or results['zig']['exit_code'] < 0 or results['cpp']['exit_code'] < 0:
                row.update({'source': source, 'input': payload.hex(), 'results': results})
            report['cases'].append(row)
        report['equivalent_cases'] = sum(row['equivalent'] for row in report['cases'])
        report['reference_crashes'] = sum(row['reference_crash'] for row in report['cases'])
        report['differences'] = sum(not row['equivalent'] and not row['reference_crash'] for row in report['cases'])
        report['case_count'] = len(report['cases'])
        save()
        print(f"Equivalent worker cases: {report['equivalent_cases']}/{report['case_count']}", flush=True)
        print(f"Reference crashes: {report['reference_crashes']}; differences: {report['differences']}", flush=True)
        if report['differences'] or arguments.functional_only:
            return int(report['differences'] != 0)

        workloads = {
            'empty': ('return nil', exchange()),
            'notification': ('return {telar.effect.notification{title=e.host,message=e.target}}', exchange()),
            'json': ('local body=telar.json.decode(e.request.body); return {telar.effect.notification{title=body.value}}', exchange()),
            'body-256k': ('return {telar.effect.notification{title=#e.request.body}}', exchange(body=b'x' * 262144)),
        }
        for name, (expression, payload) in workloads.items():
            entry.write_text(plugin(expression))
            samples = []
            for pair in range(arguments.pairs):
                order = ['zig', 'cpp'] if pair % 2 == 0 else ['cpp', 'zig']
                sample = {language: timed(binaries[language], entry, framed(payload), arguments.iterations)
                          for language in order}
                if sample['zig']['checksum'] != sample['cpp']['checksum']:
                    raise RuntimeError(f'{name} produced different effects')
                sample['ratio'] = sample['cpp']['elapsed_ns'] / sample['zig']['elapsed_ns']
                samples.append(sample)
                report['benchmarks'][name] = {'pairs': samples, 'iterations': arguments.iterations,
                                              'cpp_wins': sum(row['ratio'] < 1 for row in samples),
                                              'median_ratio': statistics.median(row['ratio'] for row in samples)}
                save()
            result = report['benchmarks'][name]
            print(f"{name}: {result['cpp_wins']}/{arguments.pairs}, ratio {result['median_ratio']:.3f}", flush=True)
    return int(any(row['cpp_wins'] < 6 for row in report['benchmarks'].values()))


if __name__ == '__main__':
    raise SystemExit(main())
