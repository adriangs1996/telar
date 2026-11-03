#!/usr/bin/env python3
"""Stage a separate local Release preview; never install or replace an app."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys


def run(command, **kwargs):
    subprocess.run([str(part) for part in command], check=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def qt_installation(cache):
    match = re.search(r'^TELAR_GUI_QT_PREFIX:INTERNAL=(.+)$', cache, re.M)
    core = re.search(r'^Qt6Core_DIR:PATH=(.+)$', cache, re.M)
    if match is None or core is None:
        raise ValueError('configure the GUI with its managed Qt dependency before packaging')
    prefix = Path(match.group(1)).resolve()
    if not Path(core.group(1)).resolve().is_relative_to(prefix):
        raise ValueError('the GUI Qt libraries do not belong to the managed Qt installation')
    return prefix


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


def write_manifest(output, binary, runtime):
    base = Path(__file__).resolve().parents[1]
    info = plistlib.loads((output / 'Contents/Info.plist').read_bytes())
    manifest = dict(status='packaged; daily adoption acceptance still open',
                    bundle=str(output), identifier=info['CFBundleIdentifier'],
                    source_gui_sha256=digest(binary), runtime_sha256=digest(runtime),
                    launcher_source_sha256=digest(base / 'tools/macos_launcher.cpp'),
                    packager_source_sha256=digest(Path(__file__)),
                    bundled_gui_sha256=digest(output / 'Contents/MacOS/telar-gui'),
                    files={str(path.relative_to(output)): digest(path)
                           for path in sorted(output.rglob('*')) if path.is_file() and not path.is_symlink()})
    (output.parent / (output.stem + '.manifest.json')).write_text(json.dumps(manifest, indent=2) + '\n')


def deploy_qml(base, build, resources, plugins, library, qtpaths):
    def query(name):
        return Path(subprocess.check_output([qtpaths, '--query', name], text=True).strip())

    imports = query('QT_INSTALL_QML')
    scanner = query('QT_INSTALL_LIBEXECS') / 'qmlimportscanner'
    modules = json.loads(subprocess.check_output(
        [str(scanner), '-rootPath', str(base / 'qt'), '-importPath', str(build), '-importPath', str(imports)],
        text=True))
    for module in modules:
        source = Path(module.get('path', ''))
        if not source.is_absolute() or not source.is_relative_to(imports):
            continue
        destination = resources / 'qml' / source.relative_to(imports)

        def nested_modules(directory, names):
            return [name for name in names if (Path(directory) / name / 'qmldir').is_file()]

        shutil.copytree(source, destination, dirs_exist_ok=True, ignore=nested_modules)
    plugin_root = query('QT_INSTALL_PLUGINS')
    for group in ('platforms', 'imageformats', 'iconengines', 'tls', 'networkinformation'):
        source = plugin_root / group
        if source.is_dir():
            shutil.copytree(source, plugins / group)
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
    runtime = prefix / 'bin' / 'telar'
    helper = prefix / 'bin' / 'telar-diagram-renderer'
    for required in (binary, command_helper, runtime, helper):
        if not required.is_file():
            parser.error(f'missing executable: {required}')
    compiler = re.search(r'^CMAKE_CXX_COMPILER:FILEPATH=(.+)$', cache, re.M)
    if compiler is None:
        compiler = re.search(r'^CMAKE_CXX_COMPILER:STRING=(.+)$', cache, re.M)
    if compiler is None:
        parser.error('cannot identify the build compiler')
    version = re.search(r'\.version\s*=\s*"([^"]+)"', (root / 'build.zig.zon').read_text()).group(1)
    contents = output / 'Contents'
    macos = contents / 'MacOS'
    resources = contents / 'Resources'
    macos.mkdir(parents=True)
    (resources / 'bin').mkdir(parents=True)
    shutil.copy2(binary, macos / 'telar-gui')
    shutil.copy2(command_helper, macos / 'telar-gui-command')
    for executable in (runtime, helper):
        shutil.copy2(executable, resources / 'bin' / executable.name)
    shutil.copy2(root / 'packaging/macos/telar.icns', resources / 'telar.icns')
    for source, name in ((prefix / 'share/telar/licenses', 'runtime'),
                         (prefix / 'share/telar/diagram-renderer/licenses', 'diagram-renderer'),
                         (base / 'licenses', 'gui')):
        if source.is_dir():
            shutil.copytree(source, resources / 'licenses' / name)
    shutil.copytree(qt_licenses, resources / 'licenses/qt')
    shutil.copy2(base / 'terminal/glyphs/LICENSE', resources / 'licenses/cell-glyphs.txt')
    shutil.copy2(root / 'src/assets/JetBrainsMono-OFL.txt', resources / 'licenses/JetBrainsMono-OFL.txt')
    shutil.copy2(root / 'src/assets/TelarForma-OFL.txt', resources / 'licenses/TelarForma-OFL.txt')
    template = (root / 'packaging/macos/Info.plist.in').read_bytes().replace(b'@VERSION@', version.encode())
    info = plistlib.loads(template)
    info.update(CFBundleDisplayName='Telar C++ Preview', CFBundleName='Telar C++ Preview',
                CFBundleIdentifier='dev.telar.cpp.preview', CFBundleExecutable='TelarPreview')
    with (contents / 'Info.plist').open('wb') as stream:
        plistlib.dump(info, stream)
    command = [compiler.group(1), '-std=c++23', '-O2', '-Wall', '-Wextra', '-Werror',
               '-I', base, base / 'tools/macos_launcher.cpp',
               base / 'platform/login_shell.cpp', '-o', macos / 'TelarPreview']
    run(command)
    library = qt_prefix / 'lib'
    executables = deploy_qml(base, build, resources, contents / 'PlugIns', library, qtpaths)
    add_search_path(macos / 'telar-gui', library)
    add_search_path(macos / 'TelarPreview', library)
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
    write_manifest(output, binary, runtime)
    print(output)


if __name__ == '__main__':
    main()
