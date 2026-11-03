#!/usr/bin/env python3
"""Compare complete PTY output and exit delivery from two owned runtimes.

The receiving probe uses the current GUI Screen header without Qt. This is a
functional oracle, not a latency or cadence benchmark. Sanitizers instrument the
probe and inline headers only; configured dependency libraries remain unchanged.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from bench_stack import executable_identity, runtime_identity
from perf_e2e import isolated_environment, stop_runtime


CASES = ('early-exit', 'immediate', 'burst', 'signal', 'forked-writer', 'coalesced')


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def build_probe(build, output, source, sanitize):
    entries = json.loads((build / 'compile_commands.json').read_text())
    entry = next(row for row in entries if Path(row['file']).name == 'launch_probe.cpp')
    command = shlex.split(entry['command'])
    command.remove('-c')
    command[command.index('-o') + 1] = str(output / source.stem)
    command = [str(source) if arg == entry['file'] else arg for arg in command]
    command[1:1] = ['-I' + str(ROOT / 'services/gui-cpp')]
    command.append(str(build / 'telar-platform/libtelar-platform.a'))
    dependencies = output / (source.stem + '.d')
    command.extend(['-MMD', '-MF', str(dependencies)])
    if sanitize:
        command.extend(['-O1', '-g', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'])
    save(output / (source.stem + '-build.json'), command)
    with (output / (source.stem + '-build.log')).open('w') as log:
        subprocess.run(command, cwd=entry['directory'], stdout=log, stderr=subprocess.STDOUT, check=True)
    headers = shlex.split(dependencies.read_text().replace('\\\n', '').partition(':')[2])
    paths = [Path(name) if Path(name).is_absolute() else Path(entry['directory']) / name for name in headers]
    save(output / (source.stem + '-dependencies.json'),
         {str(file.resolve()): hashlib.sha256(file.read_bytes()).hexdigest()
          for file in paths if file.is_file()})
    return output / source.stem


def exercise(runtime, probe, directory, case, sanitize):
    environment = isolated_environment(directory)
    environment['TELAR_HISTORY'] = str(directory / 'history.db')
    for name in ('DYLD_INSERT_LIBRARIES', 'DYLD_LIBRARY_PATH', 'DYLD_FRAMEWORK_PATH'):
        environment.pop(name, None)
    if sanitize:
        environment.update(ASAN_OPTIONS='detect_leaks=0', UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
    try:
        started = subprocess.run([str(runtime), 'server', '--background', '--no-config', '--no-session'],
                                 env=environment, cwd=directory, capture_output=True, text=True, timeout=15)
        (directory / 'start.log').write_text(started.stdout + started.stderr)
        started.check_returncode()
        identity = runtime_identity(environment['TELAR_SOCKET_PATH'], runtime)
        save(directory / 'runtime-identity.json', identity)
        if identity['sha256'] != executable_identity(runtime)['sha256']:
            raise ValueError('Connected runtime differs from selected binary')
        command = [str(probe), environment['TELAR_SOCKET_PATH'], case, str(directory),
                   str(directory / 'canonical.bin'), str(probe)]
        result = subprocess.run(command, env=environment, cwd=directory, capture_output=True, text=True, timeout=45)
        (directory / 'probe.log').write_text(result.stdout + result.stderr)
        report = dict(case=case, command=command, exit_code=result.returncode, stderr=result.stderr)
        if result.returncode == 0:
            report.update(result=json.loads(result.stdout),
                          canonical_sha256=hashlib.sha256((directory / 'canonical.bin').read_bytes()).hexdigest())
        save(directory / 'result.json', report)
        return report
    finally:
        cleanup = stop_runtime(runtime, environment)
        save(directory / 'cleanup.json', cleanup)
        if not all(cleanup[key] for key in ('cleanup_complete', 'exited', 'children_exited')):
            raise RuntimeError(f'Incomplete owned-process cleanup: {cleanup}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True, help='Configured runtime build with launch-probe compile command and platform archive')
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sanitize', action='store_true')
    parser.add_argument('--negative-control', action='store_true', help='Require rejection of a deliberately corrupted expected transcript')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, exist_ok=False)
    source = output / 'child_exit_probe.cpp'
    shutil.copy2(Path(__file__).with_name(source.name), source)
    shutil.copy2(__file__, output / Path(__file__).name)
    runtimes = {'A': args.before.resolve(strict=True), 'B': args.after.resolve(strict=True)}
    manifest = dict(scope=__doc__, sanitize=args.sanitize, build=str(args.build.resolve()),
                    runtimes={label: executable_identity(binary) for label, binary in runtimes.items()},
                    platform_archive=executable_identity(args.build.resolve() / 'telar-platform/libtelar-platform.a'),
                    sources={file.name: hashlib.sha256(file.read_bytes()).hexdigest()
                             for file in (source, Path(__file__), ROOT / 'services/gui-cpp/terminal/screen.hpp')})
    save(output / 'manifest.json', manifest)
    probe = build_probe(args.build.resolve(), output, source, args.sanitize)
    manifest['probe'] = executable_identity(probe)
    save(output / 'manifest.json', manifest)
    results = []
    for case in CASES:
        for label, runtime in runtimes.items():
            result = exercise(runtime, probe, output / (label + '-' + case), case, args.sanitize)
            if result['exit_code'] != 0:
                raise RuntimeError(f'{label}/{case}: {result["stderr"]}')
        before = (output / ('A-' + case) / 'canonical.bin').read_bytes()
        after = (output / ('B-' + case) / 'canonical.bin').read_bytes()
        if before != after:
            raise ValueError(f'{case}: canonical PTY text or exit status differs')
        results.append(dict(case=case, bytes=len(before), sha256=hashlib.sha256(before).hexdigest(), exact=True))
        save(output / 'comparisons.json', results)
        print(case + ': exact', flush=True)
    if args.negative_control:
        negative = output / 'child_exit_negative.cpp'
        text = source.read_text()
        needle = 'pane->expected = outputFor(index, (mode == "immediate" || mode == "early-exit") ? 0 : burst_lines);'
        if text.count(needle) != 1:
            raise ValueError('Negative control insertion point changed')
        negative.write_text(text.replace(needle, needle + '\n    if (mode == "burst") { pane->expected[0] = \'Z\'; }'))
        negative_probe = build_probe(args.build.resolve(), output, negative, args.sanitize)
        report = exercise(runtimes['A'], negative_probe, output / 'negative', 'burst', args.sanitize)
        if report['exit_code'] != 1 or 'Complete PTY text differs' not in report['stderr']:
            raise ValueError('Expected transcript mutation did not produce a clean rejection')
        save(output / 'negative-control.json', report)
    save(output / 'result.json', dict(passed=True, cases=len(results), performance_eligible=False,
                                     negative_control=args.negative_control))


if __name__ == '__main__':
    main()
