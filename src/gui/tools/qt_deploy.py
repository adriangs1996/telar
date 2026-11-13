"""What the macOS and Linux packagers share: the managed Qt and the QML modules and plugins the GUI loads."""

import json
from pathlib import Path
import re
import shutil
import subprocess


def qt_installation(cache):
    match = re.search(r'^TELAR_GUI_QT_PREFIX:INTERNAL=(.+)$', cache, re.M)
    core = re.search(r'^Qt6Core_DIR:PATH=(.+)$', cache, re.M)
    if match is None or core is None:
        raise ValueError('configure the GUI with its managed Qt dependency before packaging')
    prefix = Path(match.group(1)).resolve()
    if not Path(core.group(1)).resolve().is_relative_to(prefix):
        raise ValueError('the GUI Qt libraries do not belong to the managed Qt installation')
    return prefix


def query(qtpaths, name):
    return Path(subprocess.check_output([str(qtpaths), '--query', name], text=True).strip())


def copy_qml_modules(base, build, destination, qtpaths):
    """Copies each Qt QML module the GUI imports, without the nested modules it does not."""
    imports = query(qtpaths, 'QT_INSTALL_QML')
    scanner = query(qtpaths, 'QT_INSTALL_LIBEXECS') / 'qmlimportscanner'
    modules = json.loads(subprocess.check_output(
        [str(scanner), '-rootPath', str(base / 'qt'), '-importPath', str(build), '-importPath', str(imports)],
        text=True))

    def nested_modules(directory, names):
        return [name for name in names if (Path(directory) / name / 'qmldir').is_file()]

    for module in modules:
        source = Path(module.get('path', ''))
        if not source.is_absolute() or not source.is_relative_to(imports):
            continue
        shutil.copytree(source, destination / source.relative_to(imports), dirs_exist_ok=True, ignore=nested_modules)


def copy_plugins(qtpaths, destination, groups):
    root = query(qtpaths, 'QT_INSTALL_PLUGINS')
    for group in groups:
        source = root / group
        if source.is_dir():
            shutil.copytree(source, destination / group)
