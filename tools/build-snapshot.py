#!/usr/bin/env python3
"""Record what a configured CMake tree compiles, links and tests, and compare two records.

A snapshot proves that a change to the build scripts builds the same binaries
without building anything. It reads three things a configure writes:

- compile_commands.json: the flags of every compiled source, keyed by
  `<target>:<source>`. Defines are compared by their effective values and
  include directories in search order; every other flag in order. Output,
  dependency-file and module-map arguments are dropped, since they only name
  files inside the build directory.
- build.ninja: per linked binary or archive, its objects (as `<target>:<source>`),
  its libraries (an archive of the tree as `target:<name>`) and its link flags.
- `ctest --show-only=json-v1`: every test with its command and properties.
  CTest only knows the command of a test whose executable is built, so a
  command is compared only when both sides have one.

Paths are written relative to placeholders, so trees in different checkouts or
build directories compare: $BUILD (the tree), $ROOT (the repository), $TOOLCHAIN,
$QT and $DEPS (the shared caches, keeping their key directories) and $SDK. Paths
are normalized lexically, so `lib/wire/../base/include` is `lib/base/include`.

    build-snapshot.py record out/dev -o dev.json
    build-snapshot.py diff dev.json out/dev
    build-snapshot.py diff runtime.json gui.json out/dev

`diff` takes snapshot files or configured trees, prints the differences grouped
by kind and exits with 1 if there are any. With --by-source it compares what is
built rather than which target builds it, for changes that move sources between
targets: each source's flags, whichever targets compile it, and each linked
binary's sources with the tree's archives expanded into theirs. Include directories that only change
order are not a difference when no header could resolve differently: no file
under one of the swapped directories exists under the other. That check reads
the directories, so it needs the trees on disk.

A snapshot also records which source directory each directory of the tree
builds, so trees that place a folder's outputs elsewhere compare: a path under
a base tree's directory for src/gui is read as the same path under the new
tree's directory for src/gui. With several base trees, the last tree is their
union: each base is compared with what the new tree builds of it, and what the
new tree builds that no base does is listed on its own.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

VERSION = 2
# Arguments that only name files of the build directory, with the arguments they consume.
DROPPED = {'-o': 1, '-c': 0, '-MD': 0, '-MMD': 0, '-MT': 1, '-MF': 1, '-MQ': 1}
# Options whose value is a separate argument; they are recorded joined to it.
SEPARATED = {'-x', '-arch', '-target', '-isysroot', '-include', '-imacros', '-Xclang', '-Xlinker',
             '-mllvm', '-framework', '-Xarch_arm64', '-Xarch_x86_64', '-install_name'}
INCLUDES = ('-isystem', '-iquote', '-idirafter', '-iframework', '-I', '-F')
OBJECT_DIR_RE = re.compile(r'(?:^|/)CMakeFiles/([^/]+)\.dir/')
LINKER_RE = re.compile(r'^(\w+?)_(EXECUTABLE|STATIC_LIBRARY|SHARED_LIBRARY|MODULE_LIBRARY)_LINKER__')
GROUP_LIMIT = 8
INSTALL_HEADER = '# Install script for directory: '
BUILD_PATH_RE = re.compile(r'\$BUILD((?:/[^/"\s:;,=]+)*)')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    record_parser = commands.add_parser('record', help='write the snapshot of a configured tree')
    record_parser.add_argument('build', type=Path)
    record_parser.add_argument('-o', '--output', type=Path, help='file to write; standard output by default')
    diff_parser = commands.add_parser('diff', help='compare two snapshots or configured trees')
    diff_parser.add_argument('trees', type=Path, nargs='+', metavar='tree',
                             help='base snapshots or trees, then the new one')
    diff_parser.add_argument('-v', '--verbose', action='store_true', help='list every member of each group')
    diff_parser.add_argument('--by-source', action='store_true',
                             help='key compilations by source and expand archives into the binaries that link them')
    args = parser.parse_args()

    if args.command == 'record':
        text = json.dumps(record(args.build), indent=1, sort_keys=True) + '\n'
        if args.output:
            args.output.write_text(text)
        else:
            sys.stdout.write(text)
        return 0

    if len(args.trees) < 2:
        parser.error('diff needs a base and a new snapshot or tree')

    *bases, new = map(load, args.trees)
    if args.by_source:
        bases, new = [by_source(base) for base in bases], by_source(new)
    if len(bases) == 1:
        report = compare(relocate(bases[0], new), new)
        print_report(report, args.verbose)
        return 1 if report['failures'] else 0

    failed = False
    for path, base in zip(args.trees, bases):
        print(f'== {path}')
        report = compare(relocate(base, new), new, subset=True)
        print_report(report, args.verbose)
        failed = failed or bool(report['failures'])

    print(f'== only in {args.trees[-1]}')
    report = extra(bases, new)
    print_report(report, args.verbose)
    return 1 if failed or report['failures'] else 0


def load(path):
    if path.is_dir():
        return record(path)

    snapshot = json.loads(path.read_text())
    if snapshot.get('version') != VERSION:
        raise SystemExit(f'{path} is a snapshot of version {snapshot.get("version")}, not {VERSION}')

    return snapshot


# Recording.

def record(build):
    build = build.resolve()
    cache = read_cache(build)
    paths = Placeholders(build, cache)
    compiled, objects = compile_entries(build, paths)
    return {
        'version': VERSION,
        'tree': {
            'source': paths.normalize(cache['CMAKE_HOME_DIRECTORY']),
            'build_type': cache.get('CMAKE_BUILD_TYPE', ''),
        },
        # Where the placeholders pointed, so diff can read the directories it compares.
        'placeholders': paths.locations(),
        'directories': source_directories(build, paths),
        'flag_sets': compiled['flag_sets'],
        'compile': compiled['sources'],
        'link': link_entries(build, paths, objects),
        'tests': test_entries(build, cache, paths),
    }


def source_directories(build, paths):
    """The source directory each directory of the tree builds, from its install script."""
    directories = {}
    for script in build.rglob('cmake_install.cmake'):
        with script.open() as lines:
            header = lines.readline()
        if header.startswith(INSTALL_HEADER):
            binary = script.parent.relative_to(build).as_posix()
            directories['' if binary == '.' else binary] = paths.path(header[len(INSTALL_HEADER):].strip())

    return directories


def read_cache(build):
    cache = {}
    for line in (build / 'CMakeCache.txt').read_text().splitlines():
        if line.startswith(('#', '//')) or '=' not in line or ':' not in line.split('=', 1)[0]:
            continue

        key, value = line.split('=', 1)
        cache[key.split(':', 1)[0]] = value

    return cache


def repository_root(source):
    for directory in (source, *source.parents):
        if (directory / '.git').exists():
            return directory

    raise SystemExit(f'{source} is not inside a Git checkout')


class Placeholders:
    """Rewrites the machine and checkout specific prefixes of paths."""

    def __init__(self, build, cache):
        root = repository_root(Path(cache['CMAKE_HOME_DIRECTORY']).resolve())
        prefixes = {'$BUILD': [build], '$ROOT': [root]}
        for name, directory in (('$TOOLCHAIN', '.toolchain'), ('$QT', '.qt-cache'), ('$DEPS', '.dependencies-cache')):
            # Reached both through the checkout's link and through the shared cache it points at.
            prefixes[name] = [root / directory, (root / directory).resolve()]
        if cache.get('CMAKE_OSX_SYSROOT'):
            prefixes['$SDK'] = [Path(cache['CMAKE_OSX_SYSROOT'])]
        self.prefixes = prefixes
        self.names = {str(path): name for name, paths in prefixes.items() for path in paths}
        # Longest first, and only whole path components: src/cli/out is no prefix of src/cli/output.
        alternatives = '|'.join(re.escape(prefix) for prefix in sorted(self.names, key=len, reverse=True))
        self.pattern = re.compile(f'({alternatives})(?=/|$|[^\\w.+@-])')

    def normalize(self, text):
        """Every known prefix in the text replaced; paths kept as written."""
        return self.pattern.sub(lambda match: self.names[match[1]], text)

    def path(self, text, directory=None):
        """A path with its prefix replaced and its `.` and `..` resolved lexically."""
        if directory is not None and not os.path.isabs(text):
            text = os.path.join(directory, text)

        return self.normalize(os.path.normpath(text)) if os.path.isabs(text) else os.path.normpath(text)

    def locations(self):
        return {name: str(paths[-1]) for name, paths in self.prefixes.items()}


def compile_entries(build, paths):
    """The flags of each compiled source, and the `<target>:<source>` key of each object."""
    flag_sets, sources, objects = {}, {}, {}
    for entry in json.loads((build / 'compile_commands.json').read_text()):
        directory = entry['directory']
        output = os.path.normpath(os.path.join(directory, entry['output']))
        target = OBJECT_DIR_RE.search(entry['output'])
        key = f'{target[1] if target else "?"}:{source_key(entry["file"], directory, paths)}'
        flags = parse_compile(entry, directory, paths)
        identity = hashlib.sha256(json.dumps(flags, sort_keys=True).encode()).hexdigest()[:16]
        flag_sets[identity] = flags
        if key in sources and sources[key] != identity:
            raise SystemExit(f'{key} is compiled twice with different flags')

        sources[key] = identity
        objects[output] = key

    return {'flag_sets': flag_sets, 'sources': sources}, objects


def source_key(file, directory, paths):
    path = paths.path(file, directory)
    return path.removeprefix('$ROOT/')


def parse_compile(entry, directory, paths):
    arguments = entry.get('arguments') or shlex.split(entry['command'])
    source = os.path.normpath(os.path.join(directory, entry['file']))
    flags = {'compiler': paths.normalize(arguments[0]), 'defines': [], 'includes': [], 'options': []}
    index = 1
    while index < len(arguments):
        argument = arguments[index]
        index += 1
        if argument in DROPPED:
            index += DROPPED[argument]
        elif argument.startswith('@') and argument.endswith('.modmap'):
            continue
        elif argument.startswith('-fmodule-output='):
            flags['options'].append('-fmodule-output')
        elif os.path.normpath(os.path.join(directory, argument)) == source:
            continue
        elif argument.startswith(('-D', '-U')):
            value = argument[2:] or arguments[index]
            index += 0 if argument[2:] else 1
            flags['defines'].append(argument[:2] + paths.normalize(value))
        elif argument.startswith(INCLUDES):
            kind = next(prefix for prefix in INCLUDES if argument.startswith(prefix))
            value = argument[len(kind):] or arguments[index]
            index += 0 if argument[len(kind):] else 1
            flags['includes'].append([kind, paths.path(value, directory)])
        elif argument in SEPARATED and index < len(arguments):
            flags['options'].append(f'{argument} {paths.normalize(arguments[index])}')
            index += 1
        else:
            flags['options'].append(paths.normalize(argument))

    return flags


def link_entries(build, paths, objects):
    """Each archive and binary the tree links, keyed by its target."""
    edges = list(ninja_link_edges(build / 'build.ninja'))
    archives = {os.path.normpath(build / output): target for target, _, output, _, _ in edges}

    def item(text):
        path = os.path.normpath(os.path.join(build, text))
        if path in objects:
            return 'object:' + objects[path]
        if path in archives:
            return 'target:' + archives[path]
        return paths.normalize(text) if text.startswith('-') else paths.path(text, build)

    entries = {}
    for target, kind, output, inputs, variables in edges:
        flags = ' '.join(variables.get(name, '') for name in ('ARCH_FLAGS', 'LANGUAGE_COMPILE_FLAGS', 'FLAGS',
                                                             'LINK_FLAGS', 'LINK_PATH'))
        entries[target] = {
            'kind': kind,
            'output': paths.path(output, build),
            'objects': [item(text) for text in inputs],
            'libraries': [item(text) for text in join_separated(shlex.split(variables.get('LINK_LIBRARIES', '')))],
            'flags': [paths.normalize(text) for text in join_separated(shlex.split(flags))],
        }

    return entries


def join_separated(arguments):
    joined, index = [], 0
    while index < len(arguments):
        if arguments[index] in SEPARATED and index + 1 < len(arguments):
            joined.append(arguments[index] + ' ' + arguments[index + 1])
            index += 2
        else:
            joined.append(arguments[index])
            index += 1

    return joined


def ninja_link_edges(manifest):
    """(target, kind, output, explicit inputs, variables) of each link edge of a CMake manifest."""
    lines = logical_lines(manifest.read_text())
    index = 0
    while index < len(lines):
        line = lines[index]
        index += 1
        if not line.startswith('build '):
            continue

        outputs, rule, inputs = parse_build(line[len('build '):])
        linker = LINKER_RE.match(rule)
        variables = {}
        while index < len(lines) and lines[index].startswith((' ', '\t')):
            name, _, value = lines[index].strip().partition(' = ')
            variables[name] = unescape(value)
            index += 1

        if not linker:
            continue

        object_dir = OBJECT_DIR_RE.search(variables.get('OBJECT_DIR', '') + '/')
        target = object_dir[1] if object_dir else rule.split('__', 1)[1].rsplit('_', 1)[0]
        kind = linker[2].lower().replace('_library', '')
        yield target, kind, outputs[0], inputs, variables


def logical_lines(text):
    """Manifest lines with `$` line continuations joined and comments dropped."""
    lines, pending = [], ''
    for line in text.splitlines():
        trailing = len(line) - len(line.rstrip('$'))
        if trailing % 2:
            pending += line[:-1]
            continue

        line = pending + (line.lstrip() if pending else line)
        pending = ''
        if line.strip() and not line.lstrip().startswith('#'):
            lines.append(line)

    return lines


def parse_build(text):
    """Outputs, rule and explicit inputs of a build statement."""
    tokens = ninja_tokens(text)
    split = next(index for index, token in enumerate(tokens) if token is COLON)
    outputs = [token for token in tokens[:split] if token != '|']
    rule, rest = tokens[split + 1], tokens[split + 2:]
    explicit = []
    for token in rest:
        if token in ('|', '||', '|@'):
            break
        explicit.append(token)

    return outputs, rule, explicit


COLON = object()


def ninja_tokens(text):
    """Split a build statement on unescaped spaces, with the first unescaped colon as a token."""
    tokens, current, index, colon_seen = [], [], 0, False
    while index < len(text):
        character = text[index]
        if character == '$' and index + 1 < len(text):
            current.append(text[index + 1])
            index += 2
            continue

        if character == ' ':
            if current:
                tokens.append(''.join(current))
                current = []
        elif character == ':' and not colon_seen:
            if current:
                tokens.append(''.join(current))
                current = []
            tokens.append(COLON)
            colon_seen = True
        else:
            current.append(character)
        index += 1

    if current:
        tokens.append(''.join(current))

    return tokens


def unescape(value):
    return re.sub(r'\$([$ :])', r'\1', value)


def test_entries(build, cache, paths):
    ctest = cache.get('CMAKE_CTEST_COMMAND', 'ctest')
    output = subprocess.run([ctest, '--test-dir', str(build), '--show-only=json-v1'],
                            capture_output=True, text=True, check=True).stdout
    tests = {}
    for test in json.loads(output).get('tests', []):
        properties = {item['name']: normalize_value(item['value'], paths) for item in test.get('properties', [])}
        # CTest records where add_test was called, which says nothing about what runs.
        properties.pop('BACKTRACE', None)
        tests[test['name']] = {
            'command': [paths.normalize(argument) for argument in test.get('command', [])],
            'properties': properties,
        }

    return tests


def normalize_value(value, paths):
    if isinstance(value, str):
        return paths.normalize(value)
    if isinstance(value, list):
        return [normalize_value(item, paths) for item in value]

    return value


# Comparing.

def by_source(snapshot):
    """The snapshot keyed by what is built: each compiled source with the flag sets of every
    target that compiles it, and each linked binary with the sources of the tree's archives
    it links in place of the archives. Archives themselves leave the comparison."""
    variants = collections.defaultdict(set)
    for key, identity in snapshot['compile'].items():
        variants[key.split(':', 1)[1]].add(identity)

    def source(item):
        return item.split(':', 2)[2] if item.startswith('object:') else item

    archives = {target: {source(item) for item in entry['objects']}
                for target, entry in snapshot['link'].items() if entry['kind'] == 'static'}
    link = {}
    for target, entry in snapshot['link'].items():
        if entry['kind'] == 'static':
            continue

        objects, libraries = {source(item) for item in entry['objects']}, []
        for item in entry['libraries']:
            if item.startswith('target:') and item[len('target:'):] in archives:
                objects |= archives[item[len('target:'):]]
            else:
                libraries.append(item)
        link[target] = {**entry, 'objects': sorted(objects), 'libraries': libraries}

    return {**snapshot, 'compile': {key: sorted(value) for key, value in variants.items()}, 'link': link}


def relocate(base, new):
    """The base snapshot with each path under one of its directories moved to the new
    tree's directory for the same source directory."""
    sources = {source: binary for binary, source in new.get('directories', {}).items()}
    moves = {}
    for binary, source in base.get('directories', {}).items():
        if source in sources and sources[source] != binary:
            moves[binary] = sources[source]
    if not moves:
        return base

    def move(match):
        path = match[1].lstrip('/')
        parts = path.split('/') if path else []
        for length in range(len(parts), -1, -1):
            prefix = '/'.join(parts[:length])
            if prefix in moves:
                moved = '/'.join(filter(None, [moves[prefix], *parts[length:]]))
                return '$BUILD' + ('/' + moved if moved else '')

        return match[0]

    return json.loads(BUILD_PATH_RE.sub(move, json.dumps(base)))


def extra(bases, new):
    """What the new tree compiles, links and tests that no base tree does."""
    groups = collections.defaultdict(lambda: collections.defaultdict(list))
    relocated = [relocate(base, new) for base in bases]
    for field, kind, member in (('compile', 'compile', 'sources'), ('link', 'link', 'targets'), ('tests', 'tests', 'tests')):
        known = set().union(*(base[field] for base in relocated))
        for key in sorted(new[field].keys() - known):
            groups[f'{kind}: only in new'][member].append(key)

    return {'groups': groups, 'failures': list(groups)}


def compare(base, new, subset=False):
    """Differences grouped by kind: {kind: {description: [members]}}, and which kinds fail.
    A subset base is one of several trees the new one unites, so what only the new tree
    has is not a difference."""
    groups = collections.defaultdict(lambda: collections.defaultdict(list))
    directories = DirectoryIndex(new.get('placeholders', {}))

    for key in sorted(base['compile'].keys() - new['compile'].keys()):
        groups['compile: only in base']['sources'].append(key)
    for key in sorted(new['compile'].keys() - base['compile'].keys()):
        if not subset:
            groups['compile: only in new']['sources'].append(key)
    for key in sorted(base['compile'].keys() & new['compile'].keys()):
        for kind, description in compare_variants(base, new, key, directories):
            groups[kind][description].append(key)

    for key in sorted(base['link'].keys() - new['link'].keys()):
        groups['link: only in base']['targets'].append(key)
    for key in sorted(new['link'].keys() - base['link'].keys()):
        if not subset:
            groups['link: only in new']['targets'].append(key)
    for key in sorted(base['link'].keys() & new['link'].keys()):
        for kind, description in compare_link(base['link'][key], new['link'][key]):
            groups[kind][description].append(key)

    for key in sorted(base['tests'].keys() - new['tests'].keys()):
        groups['tests: only in base']['tests'].append(key)
    for key in sorted(new['tests'].keys() - base['tests'].keys()):
        if not subset:
            groups['tests: only in new']['tests'].append(key)
    for key in sorted(base['tests'].keys() & new['tests'].keys()):
        for field in ('command', 'properties'):
            # CTest names a command only once its executable exists, so a tree that
            # has not been built yet has none to compare.
            if field == 'command' and not (base['tests'][key][field] and new['tests'][key][field]):
                continue
            if base['tests'][key][field] != new['tests'][key][field]:
                description = f'{field}: {json.dumps(base["tests"][key][field])} -> {json.dumps(new["tests"][key][field])}'
                groups['tests: changed'][description].append(key)

    return {'groups': groups, 'failures': [kind for kind in groups if not kind.startswith('equivalent')]}


def compare_variants(base, new, key, directories):
    """The differences of a compiled source: of its one flag set, or by source of the flag sets
    the targets that compile it use, each new one against the closest old one."""
    before, after = base['compile'][key], new['compile'][key]
    if isinstance(before, str):
        yield from compare_flags(base['flag_sets'][before], new['flag_sets'][after], directories)
        return

    old = {json.dumps(base['flag_sets'][identity], sort_keys=True): base['flag_sets'][identity] for identity in before}
    current = {json.dumps(new['flag_sets'][identity], sort_keys=True): new['flag_sets'][identity] for identity in after}
    for text in sorted(current.keys() - old.keys()):
        candidates = [list(compare_flags(flags, current[text], directories)) for flags in old.values()]
        yield from min(candidates, key=len)
    if old.keys() - current.keys() and not current.keys() - old.keys():
        yield 'compile: flag sets only in base', f'{len(old)} -> {len(current)} flag sets'


def compare_flags(before, after, directories):
    if before['compiler'] != after['compiler']:
        yield 'compile: compiler', f'{before["compiler"]} -> {after["compiler"]}'

    old, new = effective_defines(before['defines']), effective_defines(after['defines'])
    for name in sorted(old.keys() | new.keys()):
        if old.get(name) != new.get(name):
            yield 'compile: defines', f'{name}: {old.get(name, "(unset)")} -> {new.get(name, "(unset)")}'

    old, new = unique(map(tuple, before['includes'])), unique(map(tuple, after['includes']))
    if old != new:
        if sorted(old) != sorted(new):
            for kind, path in [entry for entry in old if entry not in new]:
                yield 'compile: include directories', f'removed {kind} {path}'
            for kind, path in [entry for entry in new if entry not in old]:
                yield 'compile: include directories', f'added {kind} {path}'
        else:
            shadowed = directories.shadowed(old, new)
            moved = ', '.join(sorted({path for _, path in moved_entries(old, new)}))
            if shadowed is None:
                yield 'compile: include order (directories not on disk)', f'moved {moved}'
            elif shadowed:
                yield 'compile: include order', f'moved {moved}; resolves differently: {", ".join(shadowed[:4])}'
            else:
                yield 'equivalent: include order without shadowed headers', f'moved {moved}'

    if before['options'] != after['options']:
        if sorted(before['options']) == sorted(after['options']):
            yield 'compile: option order', f'{" ".join(before["options"])} -> {" ".join(after["options"])}'
        else:
            yield 'compile: options', describe_lists(before['options'], after['options'])


def effective_defines(defines):
    """The value each macro ends with, as the compiler applies -D and -U in order."""
    values = {}
    for define in defines:
        name, _, value = define[2:].partition('=')
        if define.startswith('-U'):
            values[name] = '(undefined)'
        else:
            values[name] = value if '=' in define else '1'

    return values


def unique(items):
    seen, result = set(), []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)

    return result


def moved_entries(old, new):
    """Entries whose position relative to another entry changed."""
    position = {entry: index for index, entry in enumerate(new)}
    moved = set()
    for index, first in enumerate(old):
        for second in old[index + 1:]:
            if position[first] > position[second]:
                moved.update((first, second))

    return moved


class DirectoryIndex:
    """Relative file paths under include directories, to tell whether reordering them matters."""

    def __init__(self, placeholders):
        self.placeholders = sorted(placeholders.items(), key=lambda item: -len(item[0]))
        self.files = {}

    def listing(self, path):
        if path not in self.files:
            real = path
            for name, location in self.placeholders:
                if real == name or real.startswith(name + '/'):
                    real = location + real[len(name):]
                    break
            if not os.path.isdir(real):
                self.files[path] = None
            else:
                self.files[path] = {os.path.relpath(os.path.join(directory, file), real)
                                    for directory, _, files in os.walk(real) for file in files}

        return self.files[path]

    def shadowed(self, old, new):
        """Headers found under two directories whose order flipped; None if one is not on disk."""
        position = {entry: index for index, entry in enumerate(new)}
        collisions = set()
        for index, first in enumerate(old):
            for second in old[index + 1:]:
                if position[first] < position[second]:
                    continue

                first_files, second_files = self.listing(first[1]), self.listing(second[1])
                if first_files is None or second_files is None:
                    return None

                collisions |= first_files & second_files

        return sorted(collisions)


def compare_link(before, after):
    if before['kind'] != after['kind'] or before['output'] != after['output']:
        yield 'link: output', f'{before["kind"]} {before["output"]} -> {after["kind"]} {after["output"]}'

    for field in ('objects', 'libraries', 'flags'):
        old, new = before[field], after[field]
        if old == new:
            continue

        if sorted(old) == sorted(new):
            yield f'link: {field} order', describe_order(old, new)
        else:
            yield f'link: {field}', describe_lists(old, new)


def describe_lists(old, new):
    removed = collections.Counter(old) - collections.Counter(new)
    added = collections.Counter(new) - collections.Counter(old)
    parts = [f'-{item}' for item in removed.elements()] + [f'+{item}' for item in added.elements()]
    return ' '.join(parts) if parts else describe_order(old, new)


def describe_order(old, new):
    return f'{" ".join(old)}\n      -> {" ".join(new)}'


def print_report(report, verbose):
    groups = report['groups']
    if not groups:
        print('No differences')
        return

    for kind in sorted(groups, key=lambda kind: (kind.startswith('equivalent'), kind)):
        descriptions = groups[kind]
        members = sum(len(items) for items in descriptions.values())
        print(f'{kind}: {members} in {len(descriptions)} group(s)')
        for description, items in sorted(descriptions.items(), key=lambda item: (-len(item[1]), item[0])):
            print(f'  {description}')
            shown = items if verbose else items[:GROUP_LIMIT]
            for item in shown:
                print(f'      {item}')
            if len(items) > len(shown):
                print(f'      ... and {len(items) - len(shown)} more')

    failing = len(report['failures'])
    print(f'{failing} kind(s) of difference' if failing else 'Equivalent')


if __name__ == '__main__':
    sys.exit(main())
