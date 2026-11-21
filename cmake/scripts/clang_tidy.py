"""Runs clang-tidy over the units of a configured tree, each with the .clang-tidy nearest it, for
cmake/scripts/check.cmake. The project is the working directory.

What a unit reported is kept in a stamp of its own, so a later run analyses again only the units whose
object, profile, clang-tidy, plugin, arguments or headers to check changed since, and reports the others
as they did then. Ninja has rebuilt every object whose source, headers, imported modules or flags changed
before this runs. A unit whose clang-tidy crashed keeps no stamp, so it is analysed again. Each stamp
sits beside the fixes its unit's run exported, a directory clang-apply-replacements reads.

A header of the project is parsed by every unit that includes it, and without more each of them checks
it. With tbc's plugin and the tree's Ninja the run gives each header to one unit, the others leave it to
that one, and a header takes the time of one check instead of one per unit that includes it.
"""
import argparse
import concurrent.futures
import json
import os
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


def dependencies(listing, build):
    """The files each object was compiled from, by the object's path, out of `ninja -t deps`."""
    files = {}
    current = None
    for line in listing.splitlines():
        if line.startswith(' '):
            if current is not None:
                current.append(line.strip())
        elif ': #deps ' in line:
            current = files.setdefault(os.path.normpath(os.path.join(build, line.split(': #deps ', 1)[0])), [])
        else:
            current = None
    return files


def project_headers(units, files, project, build):
    """The real paths of the project's files each unit includes, by source: under the project and outside
    the build tree, which holds what is generated. Nothing when some unit has no record of its files, as
    a header only that unit includes would then go to no unit."""
    real = {}

    def resolve(path):
        if path not in real:
            real[path] = os.path.realpath(path)
        return real[path]

    def inside(path, directory):
        return path.startswith(directory + os.sep)

    headers = {}
    for source, output in units.items():
        listed = files.get(os.path.normpath(output))
        if listed is None:
            return None
        own = resolve(source)
        found = set()
        for path in listed:
            # A path that does not start in the project is the SDK's or the toolchain's.
            if inside(os.path.normpath(path), project):
                resolved = resolve(path)
                if resolved != own and inside(resolved, project) and not inside(resolved, build):
                    found.add(resolved)
        headers[source] = found
    return headers


def owned_headers(headers):
    """The headers each unit checks, by source: every header goes to one of the units that include it, the
    one beside it that bears its name when there is one, and otherwise the nearest in the tree."""
    including = {}
    for source in sorted(headers):
        for header in headers[source]:
            including.setdefault(header, []).append(source)
    owned = {source: [] for source in headers}
    for header in sorted(including):
        directory, stem = os.path.dirname(header), Path(header).stem

        def distance(source):
            beside = os.path.dirname(source) == directory and Path(source).stem == stem
            return (not beside, -len(os.path.commonpath([source, header])), source)

        owned[min(including[header], key=distance)].append(header)
    return owned


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--clang-tidy', required=True, type=Path)
    parser.add_argument('--plugin', type=Path, help='a plugin clang-tidy loads, tbc-tidy-scope')
    parser.add_argument('--ninja', type=Path, help="the tree's Ninja, whose record of each object's files gives each header to one unit")
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

    # The headers each unit checks, or nothing when every unit checks every header it parses. They follow
    # from the units and from what each object was compiled from, so they are read again only when the
    # units differ from the last run's or an object is newer than what that run kept.
    owned = None
    if arguments.plugin and arguments.ninja:
        kept_owned = arguments.stamps.with_suffix('.owned')
        since = modified(kept_owned)
        if since != 0 and all(modified(output) < since for output in units.values()):
            recorded = json.loads(kept_owned.read_text())
            if sorted(recorded) == sorted(units):
                owned = recorded
        if owned is None:
            build = os.path.realpath(arguments.build)
            listing = subprocess.run([str(arguments.ninja), '-C', build, '-t', 'deps'], stdout=subprocess.PIPE, text=True, check=True).stdout
            headers = project_headers(units, dependencies(listing, build), os.path.realpath(os.getcwd()), build)
            if headers is None:
                print(f'{arguments.name}: Ninja has no record of the files of some unit, so every unit checks every header it includes', flush=True)
                kept_owned.unlink(missing_ok=True)
            else:
                owned = owned_headers(headers)
                kept_owned.write_text(json.dumps(owned))

    tool = max(modified(arguments.clang_tidy), modified(arguments.plugin))
    fresh, stale = [], []
    for source, output in units.items():
        stamp = stamp_of[source]
        since = modified(stamp)
        current = since != 0 and all(moment < since for moment in (modified(output), modified(profile(source)), tool))
        if current:
            recorded = json.loads(stamp.read_text())
            current = (recorded.get('checks') == arguments.checks and recorded.get('extra', []) == arguments.extra_arg
                       and recorded.get('owned') == (owned[source] if owned is not None else None))
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
        environment = None
        if owned is not None:
            listed = stamp.with_suffix('.headers')
            listed.write_text(''.join(header + '\n' for header in owned[source]))
            environment = dict(os.environ, TBC_PARSED_SCOPE_HEADERS=str(listed))
        result = subprocess.run([*command, source], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=environment)
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
                record = {'checks': arguments.checks, 'extra': arguments.extra_arg, 'code': code, 'output': output,
                          'owned': owned[source] if owned is not None else None}
                stamp_of[source].write_text(json.dumps(record))
            else:
                stamp_of[source].unlink(missing_ok=True)

    if failed:
        print(f'{arguments.name}: {len(failed)} of {len(units)} units failed:', *sorted(failed), sep='\n  ')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
