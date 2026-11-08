#!/usr/bin/env python3
"""Stage a Release Telar.app (--release) or a separate local preview; never install or replace an app."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

from qt_deploy import copy_plugins, copy_qml_modules, qt_installation


def run(command, **kwargs):
    subprocess.run([str(part) for part in command], check=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def add_search_path(binary, library):
    commands = subprocess.check_output(['/usr/bin/otool', '-l', str(binary)], text=True)
    paths = re.findall(r'\bpath (.+) \(offset \d+\)', commands)
    if str(library) not in paths:
        run(['/usr/bin/install_name_tool', '-add_rpath', library, binary])


def sign_bundle(output, linkage):
    objects = json.loads(linkage.read_text())['objects']
    targets = [output / entry['file'] for entry in objects if '.framework/' not in entry['file']]
    targets.extend(sorted((output / 'Contents/Frameworks').glob('*.framework')))
    for target in targets:
        run(['/usr/bin/codesign', '--force', '--sign', '-', target])
    run(['/usr/bin/codesign', '--force', '--sign', '-', output])
    for target in targets:
        run(['/usr/bin/codesign', '--verify', '--strict', target])
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', output])


def write_manifest(output, binary, cli, runtime):
    base = Path(__file__).resolve().parents[1]
    info = plistlib.loads((output / 'Contents/Info.plist').read_bytes())
    manifest = dict(status='packaged; daily adoption acceptance still open',
                    bundle=str(output), identifier=info['CFBundleIdentifier'],
                    source_gui_sha256=digest(binary), cli_sha256=digest(cli), runtime_sha256=digest(runtime),
                    launcher_source_sha256=digest(base / 'tools/macos_launcher.cpp'),
                    packager_source_sha256=digest(Path(__file__)),
                    bundled_gui_sha256=digest(output / 'Contents/MacOS/telar-gui'),
                    files={str(path.relative_to(output)): digest(path)
                           for path in sorted(output.rglob('*')) if path.is_file() and not path.is_symlink()})
    (output.parent / (output.stem + '.manifest.json')).write_text(json.dumps(manifest, indent=2) + '\n')


def deploy_qml(base, build, resources, plugins, library, qtpaths):
    copy_qml_modules(base, build, resources / 'qml', qtpaths)
    copy_plugins(qtpaths, plugins, ('platforms', 'imageformats', 'iconengines', 'tls', 'networkinformation'))
    executables = []
    for directory in (resources / 'qml', plugins):
        for binary in directory.rglob('*.dylib'):
            # Only staged copies change; resolve plugins against the same private
            # Qt build as the GUI, never whichever Qt tools happen to be on PATH.
            add_search_path(binary, library)
            executables.append(f'-executable={binary}')
    return executables


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    base = Path(__file__).resolve().parents[1]
    root = base.parents[1]
    parser.add_argument('--build', type=Path, default=base / 'out')
    parser.add_argument('--runtime-prefix', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=base / 'out-adoption' / 'Telar C++ Preview.app')
    parser.add_argument('--macdeployqt', type=Path, help='Explicit deployment tool override')
    parser.add_argument('--qtpaths', type=Path, help='Explicit Qt paths tool override')
    parser.add_argument('--release', action='store_true', help='Name and identify the bundle as the Telar release, not the side-by-side preview')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('macOS packaging must run on macOS')
    build = args.build.resolve()
    prefix = args.runtime_prefix.resolve()
    output = args.output.absolute()
    cache = (build / 'CMakeCache.txt').read_text()
    if 'CMAKE_BUILD_TYPE:STRING=Release\n' not in cache:
        parser.error('the GUI build must be Release')
    if output.exists() or output.is_symlink():
        parser.error('output already exists; choose a new candidate path')
    try:
        qt_prefix = qt_installation(cache)
    except ValueError as error:
        parser.error(str(error))
    qtpaths = args.qtpaths or qt_prefix / 'bin/qtpaths'
    macdeployqt = args.macdeployqt or qt_prefix / 'bin/macdeployqt'
    for tool in (qtpaths, macdeployqt):
        if not tool.is_file():
            parser.error(f'missing managed Qt tool: {tool}')
    qt_licenses = qt_prefix / 'share/licenses/qt'
    if not qt_licenses.is_dir():
        parser.error(f'missing managed Qt licenses: {qt_licenses}')
    binary = build / 'telar-gui'
    command_helper = build / 'telar-gui-command'
    launcher_binary = build / 'telar-gui-launcher'
    cli = prefix / 'bin' / 'telar'
    runtime = prefix / 'bin' / 'telar-runtime'
    helper = prefix / 'bin' / 'telar-diagram-renderer'
    config_check = prefix / 'bin' / 'telar-config-check'
    for required in (binary, command_helper, launcher_binary, cli, runtime, helper, config_check):
        if not required.is_file():
            parser.error(f'missing executable: {required}')
    version = (root / 'VERSION').read_text().strip()
    contents = output / 'Contents'
    macos = contents / 'MacOS'
    resources = contents / 'Resources'
    macos.mkdir(parents=True)
    (resources / 'bin').mkdir(parents=True)
    shutil.copy2(binary, macos / 'telar-gui')
    shutil.copy2(command_helper, macos / 'telar-gui-command')
    for executable in (cli, runtime, helper, config_check):
        shutil.copy2(executable, resources / 'bin' / executable.name)
    shutil.copy2(root / 'packaging/macos/telar.icns', resources / 'telar.icns')
    for source, name in ((prefix / 'share/telar/licenses', 'runtime'),
                         (prefix / 'share/telar/diagram-renderer/licenses', 'diagram-renderer'),
                         (base / 'licenses', 'gui')):
        if source.is_dir():
            shutil.copytree(source, resources / 'licenses' / name)
    shutil.copytree(qt_licenses, resources / 'licenses/qt')
    shutil.copy2(base / 'terminal/glyphs/LICENSE', resources / 'licenses/cell-glyphs.txt')
    shutil.copy2(root / 'assets/JetBrainsMono-OFL.txt', resources / 'licenses/JetBrainsMono-OFL.txt')
    shutil.copy2(root / 'assets/TelarForma-OFL.txt', resources / 'licenses/TelarForma-OFL.txt')
    template = (root / 'packaging/macos/Info.plist.in').read_bytes().replace(b'@VERSION@', version.encode())
    info = plistlib.loads(template)
    if not args.release:
        info.update(CFBundleDisplayName='Telar C++ Preview', CFBundleName='Telar C++ Preview',
                    CFBundleIdentifier='dev.telar.cpp.preview', CFBundleExecutable='TelarPreview')
    launcher = macos / info['CFBundleExecutable']
    with (contents / 'Info.plist').open('wb') as stream:
        plistlib.dump(info, stream)
    shutil.copy2(launcher_binary, launcher)
    library = qt_prefix / 'lib'
    executables = deploy_qml(base, build, resources, contents / 'PlugIns', library, qtpaths)
    add_search_path(macos / 'telar-gui', library)
    add_search_path(launcher, library)
    (resources / 'qt.conf').write_text('[Paths]\nPlugins = PlugIns\nQmlImports = Resources/qml\n')
    deployment_log = output.parent / (output.stem + '.deployment.log')
    with deployment_log.open('w') as stream:
        deployment = subprocess.run(
            [str(part) for part in [macdeployqt, output, f'-libpath={library}', '-no-plugins', '-no-codesign',
                                   f'-executable={macos / "telar-gui"}', *executables, '-verbose=1']],
            stdout=stream, stderr=subprocess.STDOUT)
    deployment.check_returncode()
    if 'ERROR:' in deployment_log.read_text():
        raise RuntimeError('Qt deployment reported errors despite its exit status')
    linkage = output.parent / (output.stem + '.linkage.json')
    run([sys.executable, base / 'tools/audit_macos_bundle.py', output, '--output', linkage])
    # Deployment changes Mach-O load commands; sign the complete staged tree afterward.
    sign_bundle(output, linkage)
    run(['/usr/bin/plutil', '-lint', contents / 'Info.plist'])
    write_manifest(output, binary, cli, runtime)
    print(output)


if __name__ == '__main__':
    main()
