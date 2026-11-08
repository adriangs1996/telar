"""Check queued frame snapshots using the source's observeFrames implementation.

Only observeFrames is transplanted into a QObject facade. Both builds use the
current Application::PresentedFrame type, real QQuickWindow signals and Qt queued
callbacks. Preparation and presentation are simulated; this does not replace
native scene, runtime acknowledgement, weak QObject lifetime or pixel tests.
This driver currently supports macOS Qt framework builds.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def observer(source):
    marker = 'void Application::observeFrames('
    if source.count(marker) != 1:
        raise ValueError('Expected exactly one observeFrames implementation')
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('Application::', 'ProbeApplication::')


def build_probe(build, source, output, sanitize=False, unsafe=False):
    output.mkdir()
    database = json.loads((build / 'compile_commands.json').read_text())
    row = next(row for row in database if row['file'].endswith('/qt/application.cpp'))
    application_header = Path(row['file']).with_suffix('.hpp')
    command = row.get('arguments') or shlex.split(row['command'])
    compiler = command[0]
    body = observer(source.read_text())
    if unsafe:
        condition = 'preparation->use_count() != 1'
        if body.count(condition) != 1:
            raise ValueError('Negative control requires the shared snapshot reuse guard')
        body = body.replace(condition, 'false')
    generated = output / 'observe_frames.inc'
    generated.write_text(body + '\n')
    (output / 'application.cpp').write_bytes(source.read_bytes())
    (output / 'application.hpp').write_bytes(application_header.read_bytes())
    probe = Path(__file__).with_name('presented_frames_probe.cpp')
    obj = output / 'probe.o'
    command[command.index('-o') + 1] = str(obj)
    command[-1] = str(probe)
    command.insert(1, '-I' + str(output))
    # The snapshot of application.hpp lives beside the generated include. Its
    # sibling headers still resolve through the build's original include paths.
    flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if sanitize else []
    command[1:1] = flags
    with (output / 'compile.log').open('w') as log:
        subprocess.run(command, cwd=row['directory'], stdout=log, stderr=subprocess.STDOUT, check=True)
    cache = (build / 'CMakeCache.txt').read_text()
    qt = Path(re.search(r'^Qt6_DIR:PATH=(.+)$', cache, re.M).group(1)).parents[2]
    binary = output / 'probe'
    link = [compiler, *flags, str(obj), '-o', str(binary), '-F' + str(qt / 'lib'),
            '-Wl,-rpath,' + str(qt / 'lib'), '-framework', 'QtQuick',
            '-framework', 'QtGui', '-framework', 'QtCore']
    with (output / 'link.log').open('w') as log:
        subprocess.run(link, cwd=row['directory'], stdout=log, stderr=subprocess.STDOUT, check=True)
    libraries = {name: digest(qt / f'lib/{name}.framework/Versions/A/{name}')
                 for name in ('QtCore', 'QtGui', 'QtQuick')}
    return binary, qt, dict(commands=[command, link], source_sha256=digest(source),
                            header_sha256=digest(application_header), generated_sha256=digest(generated),
                            probe_source_sha256=digest(probe), binary_sha256=digest(binary),
                            libraries=libraries, sanitized_translation_unit=sanitize)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sanitize', action='store_true')
    parser.add_argument('--negative-control', action='store_true')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('This driver requires a macOS Qt framework build')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    variants = [('A', args.before, False), ('B', args.after, False)]
    if args.negative_control:
        variants.append(('unsafe', args.after, True))
    results = {}
    for label, source, unsafe in variants:
        binary, qt, identity = build_probe(args.build.resolve(), source.resolve(), output / label,
                                          args.sanitize, unsafe)
        env = os.environ.copy()
        for key in ('DYLD_INSERT_LIBRARIES', 'DYLD_LIBRARY_PATH', 'DYLD_FRAMEWORK_PATH', 'DYLD_PRINT_LIBRARIES'):
            env.pop(key, None)
        env.update(QT_QPA_PLATFORM='offscreen', QT_PLUGIN_PATH=str(qt / 'plugins'))
        if args.sanitize:
            env.update(ASAN_OPTIONS='detect_leaks=0', UBSAN_OPTIONS='halt_on_error=1')
        run = subprocess.run([str(binary)], env=env, capture_output=True, text=True, timeout=30)
        results[label] = dict(identity=identity, exit_code=run.returncode, stdout=run.stdout, stderr=run.stderr)
        (output / 'result.json').write_text(json.dumps(results, indent=2) + '\n')
        expected = 1 if unsafe else 0
        if run.returncode != expected or (unsafe and run.stderr.strip() != 'Frame snapshot oracle mismatch'):
            raise RuntimeError(f'{label} failed: {run.returncode}: {run.stderr}')
        print(json.dumps(dict(variant=label, exit_code=run.returncode, output=run.stdout.strip())))
    if results['A']['stdout'] != results['B']['stdout']:
        raise RuntimeError('Frame delivery sequences differ')


if __name__ == '__main__':
    main()
