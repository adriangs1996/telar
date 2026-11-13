#!/usr/bin/env python3
"""Map every tracked file under lib/ and src/ to its place in the module tree, and move it.

The folder is the module: `telar.base.memory` lives in `lib/base/memory/memory.cppm`, and
`telar.runtime.terminal.control` in `src/runtime/terminal/control/control.cppm`. Names are
not changed, only paths:

- An interface unit is `<folder>/<last segment>.cppm`.
- A partition unit is `<folder>/<last segment>-<partition>`, keeping its extension.
- An implementation unit goes to the folder of the module it declares, with its file name.
  Platform units keep their `linux/` or `macos/` folder below the module folder.
- Every other file keeps its path below its tree, and the tree is renamed as `ROOTS` says.

Usage:
  move-cpp-tree.py --dry-run      print every move and fail if a file has no destination
  move-cpp-tree.py --write-map    regenerate docs/build/tree-moves.json
  move-cpp-tree.py --apply        move the files with git mv, following the same mapping
"""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MAP = 'docs/build/tree-moves.json'

# Every first-level folder of lib/ and src/, with its destination and the reason. A folder that
# is missing here has no destination, so a new library cannot slip through without a decision.
ROOTS = {
    'lib/clipboard': ('lib/clipboard', 'C ABI library shared with Objective-C++; it declares no '
                      'module, so no module name gives it a path'),
    'lib/ebnf': ('lib/ebnf', 'already named after its modules (telar.ebnf.*)'),
    'lib/tbc': ('lib/tbc', 'Clang tool and annotation headers; it declares no module, and P6.2 '
                'splits tbc/view.hpp'),
    'lib/telar-base': ('lib/base', 'telar.base.*'),
    'lib/telar-client': ('lib/client', 'telar.client and telar.client.protocol; P3.2 to P3.5 '
                         'move the protocol to lib/wire'),
    'lib/telar-config': ('lib/config', 'telar.config'),
    'lib/telar-git': ('lib/git', 'telar.git and its partitions; P4.1 decides whether it joins '
                      'the git family of telar.platform'),
    'lib/telar-lua': ('lib/lua', 'telar.lua; the Lua VM stays in vendor/'),
    'lib/telar-machines': ('lib/machines', 'telar.machines'),
    'lib/telar-platform': ('lib/platform', 'telar.platform and telar.platform.primitives'),
    'lib/telar-plugins': ('lib/plugins', 'telar.plugins'),
    'lib/telar-render': ('lib/render', 'telar.render.*'),
    'lib/telar-shell': ('lib/shell', 'telar.shell.syntax'),
    'lib/telar-tls': ('lib/tls', 'telar.tls'),
    'lib/telar-vocabulary': ('lib/vocabulary', 'telar.vocabulary; P10.1 may fold it into its '
                             'only importer'),
    'src/auth-daemon': ('src/auth-daemon', 'one main.cpp without modules and no -cpp suffix '
                        'to drop'),
    'src/cli-cpp': ('src/cli', 'telar.cli.*'),
    'src/gui-cpp': ('src/gui', 'telar.gui.*'),
    'src/runtime-cpp': ('src/runtime', 'telar.runtime.*'),
}
# A tree that is already in place maps onto itself, so a moved tree yields no moves.
DESTINATIONS = {target for target, _ in ROOTS.values()}
# The first segment after `telar.` that names a process tree in src/. Any other module is a library.
PROCESSES = {'runtime': 'src/runtime', 'gui': 'src/gui', 'cli': 'src/cli'}
PLATFORMS = ('linux', 'macos')
MODULE_SOURCES = ('.cppm', '.cpp')
COMMENTS = re.compile(r'//[^\n]*|/\*.*?\*/', re.S)
DECLARATION = re.compile(r'^[ \t]*(export[ \t]+)?module[ \t]+([A-Za-z_][\w.]*)(?::([A-Za-z_][\w.]*))?[ \t]*;',
                         re.M)


class MappingError(Exception):
    pass


def declaration(text):
    """Return (exported, module, partition) for a named module unit, or None."""
    match = DECLARATION.search(COMMENTS.sub('', text))
    if not match:
        return None

    return bool(match[1]), match[2], match[3]


def module_folder(name):
    parts = name.split('.')
    if parts[0] != 'telar' or len(parts) < 2:
        raise MappingError(f'module {name} is outside the telar namespace')

    if parts[1] in PROCESSES:
        if len(parts) < 3:
            raise MappingError(f'module {name} names a process tree, not a module in it')

        return PurePosixPath(PROCESSES[parts[1]], *parts[2:])

    return PurePosixPath('lib', *parts[1:])


def tree_of(path):
    parts = PurePosixPath(path).parts
    return '/'.join(parts[:2]) if len(parts) > 2 else None


def unit_destination(path, unit):
    exported, name, partition = unit
    source = PurePosixPath(path)
    folder = module_folder(name)
    last = name.rsplit('.', 1)[-1]
    if partition:
        return folder / f'{last}-{partition}{source.suffix}'

    if exported:
        if source.suffix != '.cppm':
            raise MappingError(f'{path}: interface of {name} is not a .cppm file')

        return folder / f'{last}.cppm'

    platform = [part for part in source.parent.parts if part in PLATFORMS]
    return folder.joinpath(*platform[-1:], source.name)


def destination(path, text):
    """Return the new path of one tracked file; `text` is read only for module sources."""
    tree = tree_of(path)
    if tree in ROOTS:
        target_tree = ROOTS[tree][0]
    elif tree in DESTINATIONS:
        target_tree = tree
    else:
        raise MappingError(f'{path}: {tree or path} has no entry in ROOTS')

    unit = declaration(text) if path.endswith(MODULE_SOURCES) and text is not None else None
    if unit is None:
        if path.endswith('.cppm'):
            raise MappingError(f'{path}: .cppm without a module declaration')

        return str(PurePosixPath(target_tree, PurePosixPath(path).relative_to(tree)))

    moved = unit_destination(path, unit)
    if not moved.is_relative_to(target_tree):
        raise MappingError(f'{path}: module {unit[1]} would leave its tree {target_tree} for {moved}')

    return str(moved)


def build_map(files, read):
    """Map each path in `files` to its destination. `read(path)` returns the text of a module source."""
    moves, errors = {}, []
    for path in files:
        try:
            moves[path] = destination(path, read(path) if path.endswith(MODULE_SOURCES) else None)
        except MappingError as error:
            errors.append(str(error))

    errors += conflicts(moves)
    return moves, errors


def conflicts(moves):
    errors = []
    owners = {}
    for source, target in moves.items():
        if target in owners:
            errors.append(f'{source} and {owners[target]} both move to {target}')

        owners[target] = source

    folders = {str(parent) for target in owners for parent in PurePosixPath(target).parents}
    errors += [f'{target} is a file and a folder' for target in sorted(owners.keys() & folders)]
    errors += [f'{source} moves onto {target} before {target} moves away'
               for source, target in moves.items()
               if target != source and target in moves and moves[target] != target]
    return errors


def tracked_files(root):
    output = subprocess.check_output(['git', 'ls-files', '-s', '-z', 'lib', 'src'], cwd=root, text=True)
    files, links = [], set()
    for entry in filter(None, output.split('\0')):
        mode, path = entry.split(' ', 1)[0], entry.split('\t', 1)[1]
        files.append(path)
        if mode == '120000':
            links.add(path)

    return sorted(files), links


def link_retargets(root, moves, links):
    """New targets for the symlinks whose target moves; dangling links are left as they are."""
    retargets = {}
    for link in sorted(links):
        target = os.readlink(root / link)
        resolved = os.path.normpath(os.path.join(os.path.dirname(link), target))
        if resolved not in moves:
            continue

        updated = os.path.relpath(moves[resolved], os.path.dirname(moves[link]))
        if updated != target:
            retargets[moves[link]] = updated

    return retargets


def document(moves, retargets):
    roots = {tree: {'destination': target, 'reason': reason} for tree, (target, reason) in ROOTS.items()}
    return json.dumps({'generator': 'tools/move-cpp-tree.py', 'roots': roots, 'files': moves, 'links': retargets},
                      indent=2, sort_keys=True) + '\n'


def prune(root, folder):
    """Remove `folder` and its parents below `root` while they are empty, as git leaves them."""
    while folder != root and not any(folder.iterdir()):
        folder.rmdir()
        folder = folder.parent


def apply(root, moves, retargets):
    for source, target in moves.items():
        if source == target:
            continue

        if (root / target).exists() or (root / target).is_symlink():
            raise MappingError(f'{target} already exists on disk')

        (root / target).parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git', 'mv', source, target], cwd=root, check=True)
        prune(root, (root / source).parent)

    for link, target in retargets.items():
        (root / link).unlink()
        (root / link).symlink_to(target)
        subprocess.run(['git', 'add', link], cwd=root, check=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--dry-run', action='store_true', help='print every move and check the mapping')
    mode.add_argument('--write-map', action='store_true', help=f'regenerate {MAP}')
    mode.add_argument('--apply', action='store_true', help='move the files with git mv')
    arguments = parser.parse_args(argv)

    files, links = tracked_files(ROOT)
    moves, errors = build_map(files, lambda path: (ROOT / path).read_text(errors='replace'))
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        print(f'{len(errors)} files without a valid destination', file=sys.stderr)
        return 1

    retargets = link_retargets(ROOT, moves, links)
    moved = sum(source != target for source, target in moves.items())
    if arguments.dry_run:
        for source, target in moves.items():
            if source != target:
                print(f'{source} -> {target}')

        for link, target in retargets.items():
            print(f'{link} links to {target}')

        print(f'{len(moves)} files: {moved} move, {len(moves) - moved} stay, 0 without destination, '
              f'{len(retargets)} links retargeted')
    elif arguments.write_map:
        (ROOT / MAP).write_text(document(moves, retargets))
        print(f'{MAP}: {len(moves)} files, {moved} move')
    else:
        apply(ROOT, moves, retargets)
        print(f'moved {moved} files and retargeted {len(retargets)} links')

    return 0


if __name__ == '__main__':
    sys.exit(main())
