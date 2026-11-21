"""Runs clang-tidy over the units of a configured tree, each with the .clang-tidy nearest it, for
cmake/scripts/check.cmake.

What a unit reported is kept in a stamp of its own, so a later run analyses again only the units whose
object, profile, clang-tidy, plugin or arguments changed since, and reports the others as they did then.
Ninja has rebuilt every object whose source, headers, imported modules or flags changed before this
runs. A unit whose clang-tidy crashed keeps no stamp, so it is analysed again. Each stamp sits beside
the fixes its unit's run exported, a directory clang-apply-replacements reads.
"""
import argparse
import concurrent.futures
import json
from pathlib import Path
import re
import subprocess
import sys

PROGRESS = re.compile(r'^\[\d+/\d+\] \(\d+/\d+\) Processing file ')


def profile(source):
    """The .clang-tidy nearest the source, which clang-tidy reads for it."""
    for directory in Path(source).parents:
        candidate = directory / '.clang-tidy'
        if candidate.is_file():
            return candidate
    return None


def modified(path):
    return path.stat().st_mtime_ns if path is not None and path.exists() else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--clang-tidy', required=True, type=Path)
    parser.add_argument('--plugin', type=Path, help='a plugin clang-tidy loads, tbc-tidy-scope')
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--stamps', required=True, type=Path)
    parser.add_argument('--jobs', required=True, type=int)
    parser.add_argument('--checks', default='', help="appended to each profile's Checks")
    parser.add_argument('--extra-arg', action='append', default=[], help='an argument added to each compile command')
    parser.add_argument('--name', required=True, help='the check, for the summary')
    parser.add_argument('units', type=Path, help='a file of source|object lines')
    arguments = parser.parse_args()

    units = {}
    for line in arguments.units.read_text().splitlines():
        if line:
            source, output = line.split('|', 1)
            units.setdefault(source, Path(output))

    arguments.stamps.mkdir(parents=True, exist_ok=True)
    stamp_of = {source: arguments.stamps / (source.replace('/', '%') + '.json') for source in units}
    # Stamps of units that left the scope would lend their fixes to clang-apply-replacements.
    kept = {stamp.name for stamp in stamp_of.values()}
    for stamp in arguments.stamps.iterdir():
        if stamp.with_suffix('.json').name not in kept:
            stamp.unlink()

    tool = max(modified(arguments.clang_tidy), modified(arguments.plugin))
    fresh, stale = [], []
    for source, output in units.items():
        stamp = stamp_of[source]
        since = modified(stamp)
        current = since != 0 and all(moment < since for moment in (modified(output), modified(profile(source)), tool))
        if current:
            recorded = json.loads(stamp.read_text())
            current = recorded.get('checks') == arguments.checks and recorded.get('extra', []) == arguments.extra_arg
        (fresh if current else stale).append(source)

    print(f'{arguments.name}: {len(stale)} of {len(units)} units changed since their last check', flush=True)
    failed = []

    for source in sorted(fresh):
        recorded = json.loads(stamp_of[source].read_text())
        if recorded['output']:
            sys.stdout.write(recorded['output'])
        if recorded['code'] != 0:
            failed.append(source)

    def analyse(source):
        stamp = stamp_of[source]
        command = [str(arguments.clang_tidy), '-p', str(arguments.build), '-quiet',
                   '--export-fixes', str(stamp.with_suffix('.yaml'))]
        if arguments.plugin:
            command.append(f'--load={arguments.plugin}')
        if arguments.checks:
            command.append(f'--checks={arguments.checks}')
        command.extend(f'--extra-arg={argument}' for argument in arguments.extra_arg)
        result = subprocess.run([*command, source], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        # A source with several database entries announces each one it processes; only what it found stays.
        output = ''.join(line for line in result.stdout.splitlines(keepends=True) if not PROGRESS.match(line))
        return source, result.returncode, output

    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.jobs) as pool:
        for future in concurrent.futures.as_completed([pool.submit(analyse, source) for source in sorted(stale)]):
            source, code, output = future.result()
            done += 1
            print(f'[{done}/{len(stale)}] {source}', flush=True)
            if output:
                sys.stdout.write(output)
            if code != 0:
                failed.append(source)
            # clang-tidy exits with 1 on errors; anything else is a crash, analysed again next time.
            if code in (0, 1):
                record = {'checks': arguments.checks, 'extra': arguments.extra_arg, 'code': code, 'output': output}
                stamp_of[source].write_text(json.dumps(record))
            else:
                stamp_of[source].unlink(missing_ok=True)

    if failed:
        print(f'{arguments.name}: {len(failed)} of {len(units)} units failed:', *sorted(failed), sep='\n  ')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
