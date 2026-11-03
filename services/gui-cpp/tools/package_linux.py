#!/usr/bin/env python3
"""Stage the Linux desktop tree: the headless tools, the GUI and the private Qt it loads.

The tree is relocatable: every ELF file finds the bundled Qt through an
$ORIGIN RUNPATH, and bin/qt.conf points Qt at the bundled plugins and QML
modules. Only the base system and the desktop session's libraries come from
the host.
"""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from qt_deploy import copy_plugins, copy_qml_modules, qt_installation

PLUGIN_GROUPS = (
    'platforms', 'platforminputcontexts', 'xcbglintegrations', 'imageformats', 'iconengines',
    'wayland-decoration-client', 'wayland-graphics-integration-client', 'wayland-shell-integration',
    'tls', 'networkinformation',
)
# A desktop session runs on X11 or Wayland; offscreen lets install.sh load Qt without a display.
PLATFORM_PREFIXES = ('libqxcb', 'libqwayland', 'libqoffscreen')
HEADLESS_TOOLS = ('telar', 'telar-runtime', 'telar-config-check', 'telar-diagram-renderer')
ELF_MAGIC = b'\x7fELF'


def run(command):
    subprocess.run([str(part) for part in command], check=True)


def is_elf(path):
    with path.open('rb') as stream:
        return stream.read(len(ELF_MAGIC)) == ELF_MAGIC


def needed(binary):
    dynamic = subprocess.check_output(['readelf', '-d', str(binary)], text=True)
    return re.findall(r'\(NEEDED\)\s+Shared library: \[(.+)\]', dynamic)


def copy_qt_libraries(binaries, qt_library, destination):
    """Copies, under its soname, every library of the managed Qt that BINARIES load, directly or not."""
    pending = list(binaries)
    while pending:
        for name in needed(pending.pop()):
            source = qt_library / name
            target = destination / name
            if source.exists() and not target.exists():
                shutil.copy2(source.resolve(), target)
                pending.append(target)


def set_runpath(binary, library):
    relative = os.path.relpath(library, binary.parent)
    run(['patchelf', '--set-rpath', '$ORIGIN' if relative == '.' else f'$ORIGIN/{relative}', binary])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    base = Path(__file__).resolve().parents[1]
    root = base.parents[1]
    parser.add_argument('--build', type=Path, required=True, help='Release GUI build configured with the managed Qt')
    parser.add_argument('--headless', type=Path, required=True, help='Unpacked headless tree whose bin holds the static tools')
    parser.add_argument('--output', type=Path, required=True, help='New directory to stage the tree in')
    args = parser.parse_args()
    if not sys.platform.startswith('linux'):
        parser.error('Linux packaging must run on Linux')
    build = args.build.resolve()
    output = args.output.absolute()
    cache = (build / 'CMakeCache.txt').read_text()
    if 'CMAKE_BUILD_TYPE:STRING=Release\n' not in cache:
        parser.error('the GUI build must be Release')
    if output.exists() or output.is_symlink():
        parser.error('output already exists; choose a new path')
    if shutil.which('patchelf') is None or shutil.which('readelf') is None:
        parser.error('packaging needs patchelf and readelf')
    try:
        qt_prefix = qt_installation(cache)
    except ValueError as error:
        parser.error(str(error))
    qtpaths = qt_prefix / 'bin/qtpaths'
    qt_licenses = qt_prefix / 'share/licenses/qt'
    for required in (qtpaths, qt_licenses):
        if not required.exists():
            parser.error(f'missing from the managed Qt: {required}')
    sources = [build / 'telar-gui', build / 'telar-gui-command']
    sources.extend(args.headless / 'bin' / tool for tool in HEADLESS_TOOLS)
    for required in sources:
        if not required.is_file():
            parser.error(f'missing executable: {required}')

    binaries = output / 'bin'
    library = output / 'lib'
    binaries.mkdir(parents=True)
    library.mkdir()
    for source in sources:
        shutil.copy2(source, binaries / source.name)
    copy_qml_modules(base, build, output / 'qml', qtpaths)
    copy_plugins(qtpaths, output / 'plugins', PLUGIN_GROUPS)
    for plugin in (output / 'plugins/platforms').iterdir():
        if not plugin.name.startswith(PLATFORM_PREFIXES):
            plugin.unlink()
    # Qt resolves these relative to the directory that holds qt.conf.
    (binaries / 'qt.conf').write_text('[Paths]\nPrefix = ..\nPlugins = plugins\nQmlImports = qml\n')

    loaded = [binaries / 'telar-gui']
    loaded.extend(path for directory in (output / 'qml', output / 'plugins')
                  for path in sorted(directory.rglob('*.so')) if is_elf(path))
    copy_qt_libraries(loaded, qt_prefix / 'lib', library)
    for binary in loaded + sorted(library.glob('*.so*')):
        set_runpath(binary, library)
        run(['strip', '--strip-unneeded', binary])

    share = output / 'share'
    (share / 'applications').mkdir(parents=True)
    (share / 'icons/hicolor/512x512/apps').mkdir(parents=True)
    shutil.copy2(root / 'packaging/linux/telar.desktop', share / 'applications/telar.desktop')
    shutil.copy2(root / 'packaging/linux/telar.png', share / 'icons/hicolor/512x512/apps/telar.png')
    licenses = share / 'telar/licenses'
    for source, name in ((args.headless / 'share/telar/licenses', 'runtime'),
                         (root / 'tools/diagram-renderer/licenses', 'diagram-renderer'),
                         (base / 'licenses', 'gui'),
                         (qt_licenses, 'qt')):
        if source.is_dir():
            shutil.copytree(source, licenses / name)
    shutil.copy2(base / 'terminal/glyphs/LICENSE', licenses / 'cell-glyphs.txt')
    shutil.copy2(root / 'src/assets/JetBrainsMono-OFL.txt', licenses / 'JetBrainsMono-OFL.txt')
    shutil.copy2(root / 'src/assets/TelarForma-OFL.txt', licenses / 'TelarForma-OFL.txt')
    print(output)


if __name__ == '__main__':
    main()
