#!/usr/bin/env python3
"""Check module ownership, import cycles and the documented textual boundaries."""
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SCOPES = ('lib/', 'src/runtime-cpp/', 'src/cli-cpp/',
          'src/gui-cpp/', 'src/auth-daemon/')


def main():
    inventory = json.loads((ROOT / 'docs/build/modules.json').read_text())
    files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard'],
                                    cwd=ROOT, text=True).splitlines()
    owned = {name for name in files if name.startswith(SCOPES) and (ROOT / name).is_file()}
    interfaces = {name for name in owned if name.endswith('.cppm')}
    if interfaces != set(inventory['interfaces']):
        raise RuntimeError('Update the interface inventory: ' + str(interfaces ^ set(inventory['interfaces'])))
    headers = {name for name in owned if name.endswith(('.h', '.hpp'))}
    boundaries = inventory['textual_boundaries']
    if headers != set(boundaries):
        raise RuntimeError('Document each live textual boundary: ' + str(headers ^ set(boundaries)))
    graph = {}
    for source in sorted(interfaces):
        text = (ROOT / source).read_text()
        match = re.search(r'^export module ([\w.:]+);', text, re.M)
        if not match or match[1] != inventory['interfaces'][source] or match[1] in graph:
            raise RuntimeError('Invalid or duplicate module ownership: ' + source)
        name = match[1]
        dependencies = re.findall(r'^(?:export )?import ([\w.:]+);', text, re.M)
        # The toolchain's libc++ provides std.
        graph[name] = {name.split(':')[0] + item if item.startswith(':') else item for item in dependencies} - {'std'}
        if '#include' in text and not text.startswith('module;'):
            raise RuntimeError('Textual dependencies need a global fragment: ' + source)
    visited, active = set(), []
    def visit(name):
        if name in active:
            raise RuntimeError('Module cycle: ' + ' -> '.join([*active, name]))
        if name in visited:
            return
        if name not in graph:
            raise RuntimeError('Missing provider: ' + name)
        active.append(name)
        for dependency in sorted(graph[name]):
            visit(dependency)
        active.pop()
        visited.add(name)
    for name in graph:
        visit(name)
    for source, owner in inventory['origin_interfaces'].items():
        if owner not in interfaces:
            raise RuntimeError('Missing migrated definition owner: ' + source)
    owned = check_header_owners(inventory['header_owners'], owned_units(owned))
    print(f'{len(graph)} module interfaces, acyclic imports, {len(headers)} justified textual boundaries, '
          f'{owned} headers reached only through their owner module')


INCLUDE_ROOTS = [str(path.relative_to(ROOT)) for path in sorted(ROOT.glob('lib/*/include*'))]
INCLUDE_RE = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.M)


def resolve(including, spelling):
    service = re.match(r'src/[^/]+', including)
    for base in [str(Path(including).parent)] + ([service[0]] if service else []) + INCLUDE_ROOTS:
        candidate = os.path.normpath(os.path.join(base, spelling))
        if (ROOT / candidate).is_file():
            return candidate
    return None


def global_fragment(text):
    match = re.search(r'^(?:export )?module [\w.:]+;', text, re.M) if text.startswith('module;') else None
    return text[:match.start()] if match else ''


def owned_units(files):
    return sorted(name for name in files if name.endswith(('.cppm', '.cpp'))
                  and not re.search(r'/(tests|tools)/', name) and global_fragment((ROOT / name).read_text()))


def check_header_owners(owners, units):
    """A header an owner module re-exports stays out of every other global fragment.

    Each module that includes it textually would carry its own copy of the header's
    declarations, and importers would merge those copies again.
    """
    owner_of = {}
    for owner, owned in owners.items():
        reached, pending = set(), [resolve(owner, s) for s in INCLUDE_RE.findall(global_fragment((ROOT / owner).read_text()))]
        while pending:
            header = pending.pop()
            if header and header not in reached:
                reached.add(header)
                pending += [resolve(header, s) for s in INCLUDE_RE.findall((ROOT / header).read_text())]
        for header in owned:
            if header not in reached:
                raise RuntimeError(f'{owner} owns {header} but does not include it')
            owner_of[header] = owner
    for unit in units:
        if unit in owners:
            continue
        fragment = global_fragment((ROOT / unit).read_text())
        for spelling in INCLUDE_RE.findall(fragment):
            header = resolve(unit, spelling)
            if header in owner_of:
                raise RuntimeError(f'{unit} includes {header}; import the module of {owner_of[header]} instead')
        for header in STANDARD_RE.findall(fragment):
            if header in CPP_STANDARD_HEADERS:
                raise RuntimeError(f'{unit} includes <{header}>; import std instead')
    return len(owner_of)


STANDARD_RE = re.compile(r'^\s*#\s*include\s+<([\w]+)>', re.M)
# C++ library headers reach module units through `import std`. C headers, their
# <c...> wrappers, <new> and <version> stay textual for macros and placement new.
CPP_STANDARD_HEADERS = set('''algorithm any array atomic barrier bit bitset charconv chrono compare complex
concepts condition_variable coroutine deque exception execution expected filesystem flat_map flat_set
format forward_list fstream functional future generator initializer_list iomanip ios iosfwd iostream
istream iterator latch limits list locale map mdspan memory memory_resource mutex numbers numeric
optional ostream print queue random ranges ratio regex scoped_allocator semaphore set shared_mutex
source_location span spanstream sstream stack stacktrace stdexcept stdfloat stop_token streambuf
string string_view syncstream system_error thread tuple type_traits typeindex typeinfo unordered_map
unordered_set utility valarray variant vector'''.split())


if __name__ == '__main__':
    main()
