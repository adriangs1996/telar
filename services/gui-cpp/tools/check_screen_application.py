#!/usr/bin/env python3
"""Compare Screen/CellReader variants with the current build's unchanged support headers."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess


def replace_required(source, before, after, count=1):
    if source.count(before) != count:
        raise ValueError(f'Expected {count} occurrences of {before!r}')
    return source.replace(before, after)


def main():
    root = Path(__file__).resolve().parents[3]
    default_reader = root / 'dlls/telar-client/include/telar_client/codecs/telar_cells.hpp'
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--before-screen', required=True, type=Path)
    parser.add_argument('--after-screen', required=True, type=Path)
    parser.add_argument('--before-reader', type=Path, default=default_reader)
    parser.add_argument('--after-reader', type=Path, default=default_reader)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--sanitize', action='store_true')
    parser.add_argument('--arch', choices=('native', 'x86_64', 'x86_64_v3'), default='native')
    parser.add_argument('--negative-control', action='store_true', help='Omit the reader cell check and require oracle rejection')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    before_reader = args.before_reader.read_text()
    after_reader = args.after_reader.read_text()
    before_screen = args.before_screen.read_text()
    after_screen = args.after_screen.read_text()
    sources = {
        'reader-before.hpp': before_reader, 'reader-after.hpp': after_reader,
        'screen-before.hpp': before_screen, 'screen-after.hpp': after_screen,
    }
    for name, source in sources.items():
        (output / name).write_text(source)
    client = output / 'telar_client'
    shutil.copytree(default_reader.parents[1], client)
    (client / 'codecs/telar_cells.hpp').write_text(after_reader)
    marker = '  struct CellRunCodec {'
    if before_reader.count(marker) != 1:
        raise ValueError('Cannot isolate the baseline CellReader')
    baseline = before_reader.split(marker)[0] + '}\n'
    baseline = replace_required(baseline, 'class CellReader {', 'class BaselineCellReader {')
    baseline = replace_required(baseline, '    CellReader(', '    BaselineCellReader(')
    baseline = replace_required(baseline, '#include "../serializers/telar_cells.hpp"', '#include "telar_client/serializers/telar_cells.hpp"')
    (output / 'baseline-reader.hpp').write_text(baseline)
    baseline_screen = replace_required(before_screen, 'auto reader = span.reader();', 'auto reader = BaselineCellReader{span.cells, span.count};', count=2)
    (output / 'oracle-before.hpp').write_text(baseline_screen)
    candidate_screen = replace_required(after_screen, 'namespace telar::gui {', 'namespace telar::gui::candidate {')
    (output / 'candidate-namespaced.hpp').write_text(candidate_screen)
    probe = Path(__file__).with_name('screen_application_probe.cpp')
    shutil.copy2(probe, output / probe.name)
    shutil.copy2(__file__, output / Path(__file__).name)

    entries = json.loads((args.build / 'compile_commands.json').read_text())
    entry = next(item for item in entries if item['file'].endswith('/tests/core_test.cpp'))
    command = list(entry['arguments']) if 'arguments' in entry else shlex.split(entry['command'])
    index = command.index('-o')
    del command[index:index + 2]
    command.remove('-c')
    command.remove(entry['file'])
    command.insert(1, '-I' + str(output))
    if args.arch != 'native':
        command[command.index('-arch') + 1] = 'x86_64'
        if args.arch == 'x86_64_v3':
            command.append('-march=x86-64-v3')
    if args.sanitize:
        command = [part for part in command if part not in ('-O3', '-O2', '-DNDEBUG')]
        command += ['-O1', '-g', '-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    executable = output / 'oracle'
    command += [str(output / probe.name), '-o', str(executable)]
    manifest = dict(scope=__doc__, build=str(args.build.resolve()), command=command,
                    arch=args.arch, sanitize=args.sanitize,
                    limits='Only Screen and CellReader vary; supporting GUI/core/base headers come from the existing build. Sanitizers instrument the probe and inline headers, not system libraries; leak checking is disabled.',
                    sources={str(path.relative_to(output)): hashlib.sha256(path.read_bytes()).hexdigest()
                             for path in output.rglob('*') if path.is_file()})
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    environment = dict(os.environ, ASAN_OPTIONS='detect_leaks=0', UBSAN_OPTIONS='halt_on_error=1')

    def compile_and_run(label):
        with (output / f'{label}-build.log').open('w') as log:
            subprocess.run(command, cwd=entry['directory'], stdout=log, stderr=log, check=True, timeout=180)
        result = subprocess.run([str(executable)], text=True, capture_output=True, env=environment, timeout=120)
        (output / f'{label}.log').write_text(result.stdout + result.stderr)
        return result

    result = compile_and_run('oracle')
    result.check_returncode()
    report = dict(oracle=json.loads(result.stdout), executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest())
    if args.negative_control:
        # Keep the qualified executable; the intentionally damaged parser builds separately.
        command[-1] = str(output / 'negative-oracle')
        executable = output / 'negative-oracle'
        damaged = after_reader.replace('      cell.validate();', '      /* Deliberately omitted by the negative control. */', 1)
        if damaged == after_reader:
            raise ValueError('Cannot construct the invalid-cell negative control')
        (output / 'negative-reader.hpp').write_text(damaged)
        reader_path = client / 'codecs/telar_cells.hpp'
        try:
            reader_path.write_text(damaged)
            result = compile_and_run('negative')
        finally:
            reader_path.write_text(after_reader)
        if result.returncode != 1 or result.stderr.strip() not in ('Validation-only reader mismatch', 'Screen differential mismatch', 'Failed frame mutated screen'):
            raise RuntimeError(f'Negative control did not produce the expected oracle rejection: {result}')
        report['negative_control'] = dict(returncode=result.returncode, error=result.stderr.strip(),
                                          source_sha256=hashlib.sha256(damaged.encode()).hexdigest())
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
