#!/usr/bin/env python3
"""Relink a private diagnostic GUI from an existing Release build.

Only three translation units are recompiled through a Clang VFS overlay.
The original executable, objects, static archives and sources are unchanged.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

from prepare_gui_phase_overlay import prepare


def build(build_directory, output):
    build_directory = build_directory.resolve()
    output = output.resolve()
    overlay = prepare(output)
    database = json.loads((build_directory / 'compile_commands.json').read_text())
    commands = []
    objects = []

    def run(command, directory, name):
        commands.append(command)
        result = subprocess.run(command, cwd=directory, capture_output=True, text=True)
        (output / (name + '.log')).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f'Diagnostic build failed: {output / (name + ".log")}')

    compiler = None
    for name in ('application', 'runtime_connection', 'terminal_item'):
        row = next(row for row in database if row['file'].endswith('/qt/' + name + '.cpp'))
        arguments = shlex.split(row['command'])
        compiler = arguments[0]
        target = output / (name + '.o')
        arguments[arguments.index('-o') + 1] = str(target)
        arguments[1:1] = ['-ivfsoverlay', str(overlay)]
        run(arguments, Path(row['directory']), name)
        objects.append(str(target))

    lines = subprocess.check_output(['ninja', '-t', 'commands', 'telar-gui'], cwd=build_directory, text=True).splitlines()
    link = next(line for line in reversed(lines) if ' -o telar-gui ' in line)
    arguments = shlex.split(link)
    start = arguments.index(compiler)
    end = arguments.index('&&', start) if '&&' in arguments[start:] else len(arguments)
    arguments = arguments[start:end]
    binary = output / 'telar-gui'
    arguments[arguments.index('-o') + 1] = str(binary)
    position = arguments.index('libgui-quick.a')
    arguments[position:position] = objects
    run(arguments, build_directory, 'link')
    manifest = dict(scope=__doc__, build_directory=str(build_directory), commands=commands,
                    original_sha256=hashlib.sha256((build_directory / 'telar-gui').read_bytes()).hexdigest(),
                    binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                    archive_sha256=hashlib.sha256((build_directory / 'libgui-quick.a').read_bytes()).hexdigest())
    (output / 'build.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-directory', type=Path, required=True)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(build(args.build_directory, args.output))


if __name__ == '__main__':
    main()
