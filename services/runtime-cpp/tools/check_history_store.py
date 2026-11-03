#!/usr/bin/env python3
"""Compare complete history query replies and allocation-failure recovery.

The configured runtime build supplies compiler/include settings. Each store
header is injected at its original include path using a private Clang overlay.
Only the probe and database.cpp are compiled; no production files are replaced.
This is a functional diagnostic, not a performance benchmark. System SQLite is
not sanitized, but its allocation callbacks participate in the failure audit.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[3]


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--before', type=Path, required=True, help='Baseline history/store.hpp')
    parser.add_argument('--after', type=Path, required=True, help='Candidate history/store.hpp')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sanitize', action='store_true')
    parser.add_argument('--x86', choices=('baseline', 'v3'), help='macOS Rosetta correctness check; not timing')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, exist_ok=False)
    source = output / 'history_store_probe.cpp'
    shutil.copy2(Path(__file__).with_name(source.name), source)
    shutil.copy2(__file__, output / Path(__file__).name)
    entries = json.loads((args.build.resolve() / 'compile_commands.json').read_text())
    entry = next(row for row in entries if Path(row['file']).name == 'history_test.cpp')
    base = shlex.split(entry['command'])
    for flag in ('-c', '-o'):
        index = base.index(flag)
        del base[index:index + 2]
    if args.x86:
        base[base.index('-arch') + 1] = 'x86_64'
        base.append('-march=' + ('x86-64' if args.x86 == 'baseline' else 'x86-64-v3'))
    if args.sanitize:
        base.extend(['-O1', '-g', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'])
    manifest = dict(scope=__doc__, sanitize=args.sanitize, x86=args.x86,
                    source_sha256=digest(source), runner_sha256=digest(Path(__file__)), variants={})
    comparisons = {}
    for label, header in (('A', args.before), ('B', args.after)):
        stage = output / label
        stage.mkdir()
        store = stage / 'store.hpp'
        shutil.copy2(header.resolve(strict=True), store)
        overlay = stage / 'overlay.json'
        save(overlay, {'version': 0, 'use-external-names': False, 'roots': [
            {'type': 'file', 'name': str(ROOT / 'services/runtime-cpp/history/store.hpp'), 'external-contents': str(store)}]})
        binary = stage / 'history-store-probe'
        dependencies = stage / 'dependencies.d'
        command = base + ['-ivfsoverlay', str(overlay), str(source),
                          str(ROOT / 'services/runtime-cpp/history/database.cpp'), '-lsqlite3', '-o', str(binary)]
        manifest['variants'][label] = dict(compile=command, store_sha256=digest(store))
        save(output / 'manifest.json', manifest)
        with (stage / 'build.log').open('w') as log:
            subprocess.run(command, cwd=entry['directory'], stdout=log, stderr=subprocess.STDOUT, check=True)
            dependency_command = base + ['-ivfsoverlay', str(overlay), '-MM', str(source)]
            with dependencies.open('w') as dependency_file:
                subprocess.run(dependency_command, cwd=entry['directory'], stdout=dependency_file, stderr=log, check=True)
        headers = shlex.split(dependencies.read_text().replace('\\\n', '').partition(':')[2])
        paths = [Path(name) if Path(name).is_absolute() else Path(entry['directory']) / name for name in headers]
        manifest['variants'][label].update(binary_sha256=digest(binary),
            dependencies={str(path.resolve()): digest(store if path.resolve() == ROOT / 'services/runtime-cpp/history/store.hpp' else path)
                          for path in paths if path.is_file()})
        manifest['variants'][label]['dependencies'][str(ROOT / 'services/runtime-cpp/history/database.cpp')] = digest(ROOT / 'services/runtime-cpp/history/database.cpp')
        save(output / 'manifest.json', manifest)
        environment = dict(os.environ)
        if args.sanitize:
            environment.update(ASAN_OPTIONS='detect_leaks=0', UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
        for batches in (8, 240):
            canonical = stage / f'canonical-{batches}.bin'
            result = subprocess.run([str(binary), str(canonical), str(batches)], env=environment,
                                    capture_output=True, text=True, timeout=300)
            (stage / f'run-{batches}.log').write_text(result.stderr)
            (stage / f'result-{batches}.json').write_text(result.stdout)
            result.check_returncode()
            report = json.loads(result.stdout)
            if report['filter_queries'] != 192 or report['live_bytes_after_teardown'] != 0:
                raise ValueError('Incomplete query or allocation audit')
            comparisons.setdefault(batches, {})[label] = dict(result=report, canonical_sha256=digest(canonical))
            save(output / 'comparisons.json', comparisons)
            print(label, batches * 64 + 512, 'entries: passed', flush=True)
    for pair in comparisons.values():
        if pair['A']['canonical_sha256'] != pair['B']['canonical_sha256']:
            raise ValueError('Complete HistoryResults payload differs')
    save(output / 'result.json', dict(passed=True, performance_eligible=False, comparisons=comparisons))


if __name__ == '__main__':
    main()
