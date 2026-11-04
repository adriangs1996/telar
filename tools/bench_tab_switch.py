#!/usr/bin/env python3
"""Pair native previous-tab actions against verified target generations.

Runs isolated complete Zig/C++ stacks with four independently updating PTYs.
This measures discrete switches; it does not qualify workspaces, continuous
120 Hz presentation, separate runtime resources or probe overhead.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import sys

from build_tab_switch_probe import build
from benchmark_host import HostLoadGate
from tab_switch_report import validate_switch


def load_harness(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    harness = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(harness)
    return harness


def negative_controls(output, library, options, zig):
    rows = []
    for control in ('wrong_tab', 'stale_generation', 'bad_checksum'):
        source = output / control
        source.mkdir()
        for name in ('gui_tui_latency.py', 'tab_switch_fixture.py', 'tab_switch_packet.py',
                     'terminal_bench_fixture.py', 'tab_switch_clock.dylib'):
            shutil.copy2(library.parent / name, source / name)
        path = source / ('tab_switch_packet.py' if control == 'bad_checksum' else 'tab_switch_fixture.py')
        contents = path.read_text()
        if control == 'bad_checksum':
            anchor = '    check = checksum(tab, generation)'
            replacement = anchor + ' ^ (1 if tab == 3 else 0)'
        else:
            anchor = 'marker(self.tab_index, self.generation)'
            replacement = 'marker(0, self.generation)' if control == 'wrong_tab' else 'marker(self.tab_index, 1)'
        if contents.count(anchor) != 1:
            raise ValueError('Negative-control source anchor changed')
        path.write_text(contents.replace(anchor, replacement))
        harness = load_harness(source / 'gui_tui_latency.py', 'switch_' + control)
        for mode in ('gui', 'gui-cpp'):
            try:
                harness.measure(mode, output / f'{control}-{mode}',
                                (zig, None, library, output / 'config.lua', options))
            except harness.ProbeFailure as failure:
                result = failure.result
                if (result['failed'] != 16 or not result['setup_complete'] or result['gpu_ms']
                        or result['initial_presentation']['presented_at'] <= 0):
                    raise ValueError('Negative control failed before reaching the target check') from failure
                row = dict(control=control, mode=mode, passed=True, failure=result['failed'],
                           completed_samples=0, source_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                rows.append(row)
                (output / 'controls.json').write_text(json.dumps(rows, indent=2) + '\n')
                print(json.dumps(row), flush=True)
            else:
                raise ValueError('The probe accepted a deliberately invalid target')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ('zig', 'cpp-gui', 'cpp-runtime', 'cpp-command', 'config', 'output'):
        parser.add_argument('--' + option, type=Path, required=True)
    parser.add_argument('--rounds', type=int, default=6)
    parser.add_argument('--first', choices=('zig', 'cpp'), default='zig', help='First stack; subsequent rounds alternate')
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--viewport', nargs=2, type=int, default=[1600, 1000])
    parser.add_argument('--float-windows', action='store_true', help='Float only the owned benchmark windows')
    parser.add_argument('--negative-controls', action='store_true', help='Reject wrong, stale and corrupt targets in both stacks')
    args = parser.parse_args()
    if args.rounds < 1 or not 1 <= args.samples <= 492 or min(args.viewport) <= 0:
        parser.error('invalid round, sample or viewport bounds')
    for name in ('zig', 'cpp_gui', 'cpp_runtime', 'cpp_command', 'config'):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    output = args.output.resolve()
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    working = output / 'working-directory'
    working.mkdir()
    library = build(output / 'probe')
    sys.path.insert(0, str(library.parent))
    harness = load_harness(library.parent / 'gui_tui_latency.py', 'switch_latency')
    from bench_stack import executable_identity, staged_runtime

    cpp = output / 'cpp'
    zig = output / 'zig'
    cpp.mkdir()
    zig.mkdir()
    for source, target in ((args.cpp_gui, cpp / 'telar-gui'), (args.cpp_runtime, cpp / 'telar'),
                           (args.cpp_command, cpp / 'telar-gui-command'), (args.zig, zig / 'telar'),
                           (args.config, output / 'config.lua')):
        shutil.copy2(source, target)
    source_files = [Path(__file__), Path(__file__).with_name('tab_switch_report.py'),
                    Path(__file__).with_name('benchmark_host.py')]
    for path in source_files:
        shutil.copy2(path, output / path.name)
    manifest = dict(scope=__doc__, negative_controls=args.negative_controls,
                    rounds=args.rounds, first=args.first, samples=args.samples, warmup=harness.WARMUP,
                    viewport=args.viewport, float_windows=args.float_windows,
                    working_directory=str(working), endpoint='MTLDrawable.presentedTime',
                    head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=Path(__file__).parent, text=True).strip(),
                    binaries={name: executable_identity(path) for name, path in
                              [('zig', zig / 'telar'), ('cpp_gui', cpp / 'telar-gui'),
                               ('cpp_runtime', cpp / 'telar'), ('cpp_command', cpp / 'telar-gui-command'), ('probe', library)]},
                    staged_runtime=staged_runtime(cpp / 'telar-gui', cpp / 'telar'),
                    source_sha256={path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in source_files},
                    config_sha256=hashlib.sha256(args.config.read_bytes()).hexdigest())
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    if args.negative_controls:
        options = argparse.Namespace(cpp_gui=cpp / 'telar-gui', cpp_runtime=cpp / 'telar', samples=1,
                                     image_size=None, input_method='key', endpoint='presented', idle_seconds=0,
                                     case='tabs', panes=4, throughput=False, text_pattern='repeat',
                                     background_mib_per_second=None, viewport=args.viewport,
                                     float_windows=args.float_windows, capture=False, cwd=working)
        negative_controls(output, library, options, zig / 'telar')
        return
    rows = []
    host = HostLoadGate(output / 'host-load.json')
    host.checkpoint('before-series')
    for round_index in range(args.rounds):
        pair = {}
        zig_first = (round_index % 2 == 0) == (args.first == 'zig')
        modes = ('gui', 'gui-cpp') if zig_first else ('gui-cpp', 'gui')
        for mode in modes:
            directory = output / f'{round_index}-{mode}'
            options = argparse.Namespace(cpp_gui=cpp / 'telar-gui', cpp_runtime=cpp / 'telar',
                                         samples=args.samples, image_size=None, input_method='key',
                                         endpoint='presented', idle_seconds=0, case='tabs', panes=4,
                                         throughput=False, text_pattern='repeat', background_mib_per_second=None,
                                         viewport=args.viewport, float_windows=args.float_windows, capture=False, cwd=working)
            with host.run(directory.name):
                row = harness.measure(mode, directory, (zig / 'telar', None, library, output / 'config.lua', options))
                receipts = [json.loads(path.read_text()) for path in sorted((directory / 'switching').glob('*.json'))]
                publications = {tab: (directory / 'switching' / f'{tab}.events').read_bytes() for tab in range(4)}
                row['switch_validation'] = validate_switch(row, receipts, publications)
                row['switch_fixtures'] = receipts
            row.update(round=round_index, case='tab-switch')
            cpu = row['measurement_user_cpu_seconds'] + row['measurement_system_cpu_seconds']
            row['summary']['gui_cpu_ms_per_input'] = cpu * 1000 / args.samples
            rows.append(row)
            pair[mode] = row
            (output / 'runs.json').write_text(json.dumps(rows, indent=2) + '\n')
            print(json.dumps(dict(round=round_index, mode=mode, summary=row['summary'])), flush=True)
        harness.validate_telar_grids(pair['gui'], pair['gui-cpp'])
    host.finish()
    pairs = [{row['mode']: row['summary'] for row in rows if row['round'] == index}
             for index in range(args.rounds)]
    summary = {metric: dict(zig=statistics.median(pair['gui'][metric] for pair in pairs),
                            cpp=statistics.median(pair['gui-cpp'][metric] for pair in pairs),
                            cpp_wins=sum(pair['gui-cpp'][metric] < pair['gui'][metric] for pair in pairs))
               for metric in ('p50_ms', 'p95_ms', 'p99_ms', 'max_ms', 'gui_cpu_ms_per_input')}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
