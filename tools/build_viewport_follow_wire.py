#!/usr/bin/env python3
"""Build the viewport fixture adapter from an explicitly pinned Zig revision.

Use the compiler/target/libc matching the independently frozen Zig runtime.
The archive and binary stay in a fresh ignored output directory; neither the
reference worktree nor its runtime is rebuilt. The manifest records all inputs.
"""

import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile


ROOT = Path(__file__).resolve().parents[1]
ADAPTER = Path(__file__).with_name('viewport_follow_wire.zig')
PATHS = ('src/core', 'lib/bytecodec', 'lib/cellcodec', 'lib/cellgrid',
         'lib/keyinput', 'lib/localsocket', 'lib/privatefile')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--target', required=True)
    parser.add_argument('--cpu', required=True)
    parser.add_argument('--libc', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    revision = subprocess.check_output(
        ['git', 'rev-parse', '--verify', '--end-of-options', args.revision + '^{commit}'],
        cwd=ROOT, text=True).strip()
    archive = subprocess.check_output(
        ['git', 'archive', '--format=tar', revision, '--', *PATHS], cwd=ROOT)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = output / 'source'
    source.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
        for member in bundle.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not (member.isdir() or member.isfile()):
                raise ValueError(f'Unsafe archive entry: {member.name}')
        bundle.extractall(source)
    adapter = source / 'src/core/viewport_follow_wire.zig'
    shutil.copy2(ADAPTER, adapter)
    binary = output / ('wire.dylib' if 'macos' in args.target else 'wire.so')
    zig = args.zig.resolve(strict=True)
    command = [str(zig), 'build-lib', '-dynamic', '-O', 'ReleaseSafe',
               '-target', args.target, '-mcpu=' + args.cpu, '-lc']
    if args.libc is not None:
        args.libc = args.libc.resolve(strict=True)
        command += ['--libc', str(args.libc)]
    for dependency in ('bytecodec', 'cellcodec', 'cellgrid', 'keyinput', 'localsocket'):
        command += ['--dep', dependency]
    command += ['-Mroot=' + str(adapter)]
    modules = dict(bytecodec=(), cellcodec=('bytecodec', 'cellgrid'),
                   cellgrid=(), keyinput=('cellgrid',), localsocket=('privatefile',),
                   privatefile=())
    for module, dependencies in modules.items():
        for dependency in dependencies:
            command += ['--dep', dependency]
        command += ['-M' + module + '=' + str(source / 'lib' / module / 'root.zig')]
    command += ['-femit-bin=' + str(binary)]
    manifest = dict(scope='Fixture wire adapter; no GUI or runtime rebuilt.',
                    revision=revision, paths=PATHS,
                    archive_sha256=hashlib.sha256(archive).hexdigest(),
                    adapter_sha256=digest(ADAPTER), compiler_sha256=digest(zig),
                    libc_sha256=None if args.libc is None else digest(args.libc),
                    command=command)
    receipt = output / 'manifest.json'
    receipt.write_text(json.dumps(manifest, indent=2) + '\n')
    with (output / 'build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    manifest['binary_sha256'] = digest(binary)
    receipt.write_text(json.dumps(manifest, indent=2) + '\n')
    print(binary)


if __name__ == '__main__':
    main()
