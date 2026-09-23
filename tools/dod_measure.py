#!/usr/bin/env python3
"""Collect paired DOD evidence from prebuilt binaries, never build during sampling."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import subprocess
import sys
import time
from types import SimpleNamespace

import gui_tui_latency

TOOLS = Path(__file__).resolve().parent
SOURCE = TOOLS.parent


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def execute(command, directory, timeout=240):
    directory.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, TELAR_PROFILE_DIR=str(directory))
    started = time.monotonic()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    with (directory / 'stdout').open('w') as out, (directory / 'stderr').open('w') as err:
        try:
            result = subprocess.run(list(map(str, command)), cwd=SOURCE, env=env, stdout=out,
                                    stderr=err, timeout=timeout)
            status = result.returncode
        except subprocess.TimeoutExpired:
            status = 'timeout'
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    receipt = dict(command=list(map(str, command)), status=status, elapsed_s=time.monotonic()-started,
                   children_user_s=after.ru_utime-before.ru_utime, children_system_s=after.ru_stime-before.ru_stime)
    save(directory / 'receipt.json', receipt)
    print(directory.name, status, flush=True)
    return receipt


def native(options, output):
    library = output / 'pixel-probe.dylib'
    subprocess.run(['clang', '-dynamiclib', '-O2', '-fobjc-arc', '-framework', 'AppKit',
                    '-framework', 'QuartzCore', '-framework', 'Metal',
                    str(TOOLS / 'gui_tui_latency.m'), '-o', str(library)], check=True)
    config = SOURCE / 'docs/performance/ghostty-comparison/config.lua'
    runs = []
    settings = SimpleNamespace(samples=options.samples, input_method='text', viewport=[1600, 1000],
                               panes=4, vsync='true', case='single', throughput=False,
                               text_pattern='variable', background_mib_per_second=None, float_windows=True)
    for repetition in range(options.rounds if options.section == 'native' else 0):
        for label in (['B0', 'B2'] if repetition % 2 == 0 else ['B2', 'B0']):
            directory = output / f'{label}-typing-{repetition}'
            try:
                row = gui_tui_latency.measure('gui', directory, (getattr(options, label.lower()) / 'telar', None, library, config, settings))
                row.update(build=label, repetition=repetition)
                runs.append(row)
            except Exception as error:
                runs.append(dict(build=label, repetition=repetition, error=repr(error)))
            save(output / 'native-runs.json', runs)
    # Scaling and contention have distinct workloads and must not be pooled with typing.
    cases = {'scaling': [('splits', 8)], 'load': [('splits-load', 4)]}.get(options.section, [('splits', 4), ('splits', 8), ('tabs', 8), ('splits-load', 4)])
    for case, panes in cases:
        settings.case, settings.panes = case, panes
        settings.samples = 50
        settings.background_mib_per_second = 1 if case.endswith('-load') else None
        directory = output / f'B2-{case}-{panes}'
        try:
            row = gui_tui_latency.measure('gui', directory, (options.b2 / 'telar', None, library, config, settings))
            runs.append(dict(build='B2', **row))
        except Exception as error:
            runs.append(dict(build='B2', case=case, panes=panes, error=repr(error)))
        save(output / 'native-runs.json', runs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--b0', required=True, type=Path, help='directory with prebuilt executables')
    parser.add_argument('--b2', required=True, type=Path)
    parser.add_argument('--b3', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--samples', type=int, default=200)
    parser.add_argument('--section', choices=['kernels', 'native', 'scaling', 'load', 'runtime', 'traces', 'capabilities'], required=True)
    options = parser.parse_args()
    if not 1 <= options.samples <= 400 or not 1 <= options.rounds <= 10:
        parser.error('samples must be 1..400 and rounds 1..10')
    for name in ('b0', 'b2', 'b3', 'output'):
        if getattr(options, name):
            setattr(options, name, getattr(options, name).resolve())
    options.output.mkdir(mode=0o700, parents=True, exist_ok=True)
    output = options.output / options.section
    output.mkdir(mode=0o700, exist_ok=False)
    binaries = {f'{label}/{binary.name}': hashlib.sha256(binary.read_bytes()).hexdigest()
                for label in ('b0', 'b2', 'b3') if getattr(options, label)
                for binary in getattr(options, label).iterdir() if binary.is_file()}
    tracked = subprocess.check_output(['git', 'ls-files', '-m', '-o', '--exclude-standard'], cwd=SOURCE, text=True).splitlines()
    manifest = dict(started_at=time.strftime('%Y-%m-%dT%H:%M:%S%z'), platform=platform.platform(),
                    cpu=subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
                    power=subprocess.check_output(['pmset', '-g', 'batt'], text=True),
                    zig=subprocess.check_output(['zig', 'version'], text=True).strip(),
                    commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=SOURCE, text=True).strip(),
                    source_files={name: hashlib.sha256((SOURCE/name).read_bytes()).hexdigest() for name in tracked if (SOURCE/name).is_file()},
                    binaries=binaries, argv=sys.argv, rounds=options.rounds, samples=options.samples)
    save(output / 'manifest.json', manifest)
    if options.section == 'kernels':
        for repetition in range(options.rounds):
            for label in (['B0', 'B2'] if repetition % 2 == 0 else ['B2', 'B0']):
                directory = getattr(options, label.lower())
                execute([directory / 'telar-dod-probe'], output / f'{label}-cpu-{repetition}')
                execute([directory / 'telar-benchmarks', '--json', '--samples', '10', '--sample-ms', '40'], output / f'{label}-bench-{repetition}')
        execute([options.b2 / 'telar-benchmarks', '--storage'], output / 'storage')
    elif options.section in ('native', 'scaling', 'load'):
        native(options, output)
    elif options.section == 'runtime':
        for label in ('B0', 'B2'):
            for detached in (False, True):
                command = [sys.executable, TOOLS / 'terminal_runtime_bench.py', '--binary', getattr(options, label.lower()) / 'telar', '--mib', '8', '--output', output / f'{label}-{"detached" if detached else "attached"}']
                execute(command + (['--detach'] if detached else []), output / f'{label}-driver-{detached}')
        execute([sys.executable, TOOLS / 'terminal_runtime_bench.py', '--binary', options.b0 / 'telar', '--mib', '64', '--sample', '--settle-seconds', '8', '--output', output / 'B1-sampled'], output / 'B1-driver')
    elif options.section == 'traces':
        if not options.b3:
            parser.error('traces requires --b3')
        for workload in ('echo', 'idle', 'scroll', 'full'):
            execute([sys.executable, TOOLS / 'gui_slot_probe.py', options.b3 / 'telar', output / workload, '--workload', workload, '--seconds', '30', '--samples', '100', '--viewport', '1600', '1000', '--workload-warmup', '5'], output / f'{workload}-driver', timeout=130)
    elif options.section == 'capabilities':
        execute(['xcrun', 'xctrace', 'list', 'templates'], output / 'templates')
        for template in ('Time Profiler', 'CPU Counters', 'Allocations'):
            execute(['xcrun', 'xctrace', 'record', '--template', template, '--time-limit', '10s', '--output', output / f'{template}.trace', '--launch', '--', options.b0 / 'telar-dod-probe'], output / template, timeout=90)
    save(output / 'complete.json', dict(finished_at=time.strftime('%Y-%m-%dT%H:%M:%S%z')))


if __name__ == '__main__':
    main()
