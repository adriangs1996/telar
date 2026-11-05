#!/usr/bin/env python3
"""Build the scroll projection oracle using an existing Ninja runtime build.

Does not rebuild runtime libraries or the runtime executable. Verification emits
length-prefixed binary records; compare complete stdout from reference/candidate
builds. Timings cover refresh and incremental frame preparation, not native input.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'services/runtime-cpp/tests/scroll_projection_probe.cpp'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def overlay_inputs(overlay):
    if overlay is None:
        return {}
    definition = json.loads(overlay.read_text())
    pending = list(definition.get('roots', []))
    result = {}
    while pending:
        entry = pending.pop()
        pending.extend(entry.get('contents', []))
        if 'external-contents' in entry:
            path = Path(entry['external-contents'])
            if not path.is_absolute():
                raise ValueError('Overlay external-contents paths must be absolute')
            result[str(path.resolve())] = digest(path)
    return result


def build_probe(build, output, overlay=None):
    build = build.resolve(strict=True)
    output = output.resolve()
    database = json.loads((build / 'compile_commands.json').read_text())
    reference = ROOT / 'services/runtime-cpp/tests/terminal_test.cpp'
    entry = next(row for row in database if Path(row['file']).resolve() == reference)
    compile_command = entry.get('arguments') or shlex.split(entry['command'])
    compile_command = list(compile_command)
    compile_command[compile_command.index('-o') + 1] = str(output / 'probe.o')
    source_index = compile_command.index(entry['file'])
    compile_command[source_index] = str(SOURCE)
    if overlay is not None:
        compile_command[1:1] = ['-ivfsoverlay', str(overlay.resolve(strict=True))]

    cache = (build / 'CMakeCache.txt').read_text().splitlines()
    ninja = next(line.split('=', 1)[1] for line in cache
                 if line.startswith('CMAKE_MAKE_PROGRAM:'))
    if 'ninja' not in Path(ninja).name:
        raise ValueError('An existing Ninja runtime build is required')
    commands = subprocess.check_output(
        [ninja, '-t', 'commands', 'control-pty-latency-probe'],
        cwd=build, text=True,
    ).splitlines()
    link_command = shlex.split(commands[-1])
    if link_command[:2] == [':', '&&']:
        link_command = link_command[2:]
    if link_command[-2:] == ['&&', ':']:
        link_command = link_command[:-2]
    if any(part in {'&&', '||', ';', '|', '>', '<'} for part in link_command):
        raise ValueError('Unsupported shell operations in generated link command')
    objects = [index for index, part in enumerate(link_command) if part.endswith('.cpp.o')]
    if len(objects) != 1:
        raise ValueError('Expected one object in the reference probe link command')
    link_command[objects[0]] = str(output / 'probe.o')
    link_command[link_command.index('-o') + 1] = str(output / 'probe')

    output.mkdir(parents=True, exist_ok=False)
    manifest = {
        'scope': 'Component only; existing runtime libraries are reused unchanged.',
        'source': {'path': str(SOURCE), 'sha256': digest(SOURCE)},
        'overlay': None if overlay is None else {
            'path': str(overlay.resolve()), 'sha256': digest(overlay),
        },
        'overlay_inputs': overlay_inputs(overlay),
        'headers': {
            name: digest(ROOT / 'services/runtime-cpp/terminal' / name)
            for name in ['terminal.hpp', 'frame_sync.hpp', 'screen.hpp',
                         'cell_projection.hpp', 'text_metadata.hpp']
        },
        'compile_directory': entry['directory'],
        'link_directory': str(build),
        'commands': [compile_command, link_command],
        'link_inputs': {},
    }
    for argument in link_command[1:]:
        path = Path(argument)
        if not path.is_absolute():
            path = build / path
        if path.is_file() and path.suffix in {'.a', '.so', '.dylib', '.tbd'}:
            manifest['link_inputs'][str(path.resolve())] = digest(path)
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for name, command, directory in [
        ('compile', compile_command, entry['directory']),
        ('link', link_command, build),
    ]:
        with (output / (name + '.log')).open('w') as log:
            subprocess.run(command, cwd=directory, stdout=log,
                           stderr=subprocess.STDOUT, check=True)
    manifest['binary_sha256'] = digest(output / 'probe')
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return output / 'probe'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-build', type=Path, required=True)
    parser.add_argument('--overlay', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(build_probe(args.runtime_build, args.output, args.overlay))


if __name__ == '__main__':
    main()
