#!/usr/bin/env python3
"""Check module ownership and paths, import cycles, re-exports, unused imports and the documented
textual boundaries."""
import argparse
import collections
import functools
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SCOPES = ('lib/', 'src/runtime/', 'src/cli/',
          'src/gui/', 'src/auth-daemon/')
# The first segment after `telar.` that names a process tree in src/; any other module is a library.
PROCESSES = {'runtime': 'src/runtime', 'gui': 'src/gui', 'cli': 'src/cli'}
PLATFORMS = ('linux', 'macos')
# Clang predefines these as object-like macros in the GNU modes, which CMake gives a
# consumer of the installed package by default (-std=gnu++23), and a macro cannot be
# a module name component there.
GNU_MACROS = {'linux', 'unix'}
# Rule 5 checks every source in SCOPES except those under a tests/ or tools/ folder and those
# under these directories. Only whole directories leave the rule: a file that breaks it goes in
# textual-includes.json until the change that fixes it.
#
# lib/tbc is TBC, a build tool and not telar code. tbc-lint is a Clang tool: its AST, matchers
# and diagnostics reach it through the Clang/LLVM headers of the linter toolchain, which offer
# no C++ named modules to import. The rest of lib/tbc (the example, the annotation headers)
# keeps the includes of its own standalone build. Telar's sources stay in the rule when they
# use TBC.
OUTSIDE_RULE_5 = ('lib/tbc/',)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write-unused-imports', action='store_true',
                        help=f'rewrite {UNUSED_IMPORTS} with the unused imports found today, then check')
    arguments = parser.parse_args()

    inventory = json.loads((ROOT / 'docs/build/modules.json').read_text())
    files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard'],
                                    cwd=ROOT, text=True).splitlines()
    owned = {name for name in files if name.startswith(SCOPES) and (ROOT / name).is_file()}
    units = {name: (ROOT / name).read_bytes() for name in owned if name.endswith(IMPORTING_SUFFIXES)}
    interfaces = {name for name in owned if name.endswith('.cppm')}
    if interfaces != set(inventory['interfaces']):
        raise RuntimeError('Update the interface inventory: ' + str(interfaces ^ set(inventory['interfaces'])))

    # Other changes move imports at the same time, so the allowlist is rewritten before any
    # other check can stop the run.
    sources = {source: (ROOT / source).read_text() for source in inventory['interfaces']}
    allowed_reexports = json.loads((ROOT / 'docs/build/reexports.json').read_text())
    provided = provided_names(sources, inventory['interfaces'], allowed_reexports, inventory['implicit_uses'])
    if arguments.write_unused_imports:
        write_unused_imports(unused_import_sites(units, provided))

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
        if GNU_MACROS & set(name.replace(':', '.').split('.')):
            raise RuntimeError(f'{source} names {name}, but a GNU mode predefines one of its components as a macro')
        graph[name] = imports_of(name, text)
        if '#include' in text and not text.startswith('module;'):
            raise RuntimeError('Textual dependencies need a global fragment: ' + source)
    check_module_paths(owned)
    namespaced = check_module_namespaces(owned, inventory.get('namespaced_folders', []),
                                         lambda path: (ROOT / path).read_text(errors='replace'))
    imports = unit_imports(owned, graph)
    check_library_layers(inventory['library_layers'], inventory['interfaces'], imports)
    upward = check_process_layers(inventory['process_layers'], inventory['upward_imports'], imports)
    domains = check_domain_targets(inventory['process_layers'], owned, lambda path: (ROOT / path).read_text())
    check_cycles(imports)
    for source, owner in inventory['origin_interfaces'].items():
        if owner not in interfaces:
            raise RuntimeError('Missing migrated definition owner: ' + source)
    allowed = json.loads((ROOT / 'docs/build/textual-includes.json').read_text())
    includes = check_includes(owned, allowed, inventory['macro_headers'], inventory['header_owners'],
                              inventory['library_owners'])
    owned = check_header_owners(inventory['header_owners'], owned_units(owned))
    reexports = check_reexports(sources, allowed_reexports)
    unused = check_unused_imports(units, provided, json.loads((ROOT / UNUSED_IMPORTS).read_text()))
    print(f'{len(graph)} module interfaces, acyclic imports, {upward} upward imports left, '
          f'{domains} domain targets depending on what they import, '
          f'{len(headers)} justified textual boundaries, {includes} textual includes left, '
          f'{owned} headers reached only through their owner module, '
          f'{reexports} re-exports left, {unused} unused imports left, '
          f'{namespaced} modules exporting into the namespace of their name')


IMPORT_RE = re.compile(r'^(?:export )?import ([\w.:]+);', re.M)


def imports_of(name, text):
    """The modules a unit of `name` imports, with its partitions spelled in full."""
    dependencies = IMPORT_RE.findall(text)

    # The toolchain's libc++ provides std.
    return {name.split(':')[0] + item if item.startswith(':') else item for item in dependencies} - {'std'}


def unit_imports(files, graph):
    """The imports of each module, its implementation units included: an import in a .cpp
    still ties the module to the component it imports."""
    imports = {name: set(dependencies) for name, dependencies in graph.items()}
    for path in sorted(name for name in files if name.endswith('.cpp')):
        text = COMMENTS_RE.sub('', (ROOT / path).read_text(errors='replace'))
        match = DECLARATION_RE.search(text)
        if not match:
            continue

        name = f'{match[2]}:{match[3]}' if match[3] else match[2]
        imports.setdefault(name, set()).update(imports_of(name, text))

    for name, dependencies in imports.items():
        for dependency in dependencies:
            if dependency not in graph:
                raise RuntimeError(f'Missing provider: {dependency}, imported by {name}')

    return imports


def check_cycles(imports):
    """No module reaches itself through imports, implementation units included: the build
    orders them, but the two modules still depend on each other."""
    visited, active = set(), []

    def visit(name):
        if name in active:
            raise RuntimeError('Module cycle: ' + ' -> '.join([*active[active.index(name):], name]))
        if name in visited:
            return

        active.append(name)
        for dependency in sorted(imports.get(name, ())):
            visit(dependency)

        active.pop()
        visited.add(name)

    for name in sorted(imports):
        visit(name)


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


def check_library_layers(layers, interfaces, imports):
    """`library_layers` in modules.json lists the libraries each library's modules may import,
    lowest layer first. A library reaching a higher one, or a sibling it does not list, rebuilds
    and drags in more than it uses."""
    library_of = {}
    for source, name in interfaces.items():
        match = re.match(r'lib/([^/]+)/', source)
        if match:
            library_of[name.split(':')[0]] = match[1]
    for name, library in library_of.items():
        if library not in layers:
            raise RuntimeError(f'Place {library} in library_layers before {name} imports anything')
    for name, dependencies in imports.items():
        library = library_of.get(name.split(':')[0])
        if library is None:
            continue
        for dependency in dependencies:
            target = library_of.get(dependency.split(':')[0])
            if target and target != library and target not in layers[library]:
                raise RuntimeError(f'{name} imports {dependency}: {library} may not depend on {target}')


def component(name, layers):
    """`lib/<library>` for a library module. For a process module, `<process>/<domain>`: the
    longest folder of `process_layers` that holds the module, so a domain may be nested
    (`gui/features/terminal/links`); a module below none of them names its top folder."""
    parts = name.split(':')[0].split('.')
    if parts[1] not in PROCESSES:
        return f'lib/{parts[1]}'

    path = parts[2:]
    domains = set(layers.get(parts[1], ()))
    for end in range(len(path), 0, -1):
        if '/'.join(path[:end]) in domains:
            return f'{parts[1]}/' + '/'.join(path[:end])
    return f'{parts[1]}/{parts[2]}'


def check_process_layers(layers, allowed, imports):
    """Rule 2: a module imports only downward. Libraries sit below every process, and
    `process_layers` in modules.json orders the components of each process, lowest first. A
    process reaches only libraries and its own components. `upward_imports` lists the upward
    imports that exist today; the change that removes one removes its entry."""
    position = {f'{process}/{folder}': index
                for process, folders in layers.items() for index, folder in enumerate(folders)}
    unplaced = {component(name, layers) for name in imports} - position.keys()
    unplaced = sorted(name for name in unplaced if not name.startswith('lib/'))
    if unplaced:
        raise RuntimeError('Place each component in process_layers: ' + ', '.join(unplaced))

    def downward(source, target):
        upper, lower = component(source, layers), component(target, layers)
        if lower.startswith('lib/'):
            return True
        if upper.startswith('lib/') or upper.split('/')[0] != lower.split('/')[0]:
            return False

        return position[lower] <= position[upper]

    upward = {f'{name} -> {dependency}'
              for name, dependencies in imports.items() for dependency in dependencies
              if not downward(name, dependency)}
    errors = [f'{edge} imports upward' for edge in sorted(upward - set(allowed))]
    errors += [f'{edge} no longer imports upward; remove it from upward_imports'
               for edge in sorted(set(allowed) - upward)]
    if errors:
        raise RuntimeError('Imports against the layer order:\n  ' + '\n  '.join(errors))

    return len(upward)


DOMAIN_CALL_RE = re.compile(r'\btelar_add_domain\(([^()]*)\)')
DOMAIN_KEYWORDS = {'SOURCES', 'MACOS_SOURCES', 'LINUX_SOURCES', 'INCLUDES', 'DEPS', 'CHECKS', 'EXCLUDE'}
DOMAIN_FILES = ('SOURCES', 'MACOS_SOURCES', 'LINUX_SOURCES')
# What telar_modules leaves out of a target's module interfaces.
UNBUILT_FOLDER_RE = re.compile(r'/(tests|tools|vendor|out(-[^/]*)?|CMakeFiles)/')


def domain_declarations(path, text):
    """The telar_add_domain calls of a CMakeLists.txt: (process, domain, {keyword: [argument]})."""
    text = re.sub(r'#[^\n]*', '', text)
    declarations = []
    for call in DOMAIN_CALL_RE.finditer(text):
        process, domain, *rest = call[1].split()
        arguments, keyword = {}, None
        for token in rest:
            if token in DOMAIN_KEYWORDS:
                keyword = token
                arguments.setdefault(keyword, [])
            elif keyword is None:
                raise RuntimeError(f'{path}: telar_add_domain({process} {domain}) has an argument before its first keyword')
            else:
                arguments[keyword].append(token)
        declarations.append((process, domain, arguments))

    return declarations


def check_domain_targets(layers, files, read):
    """Rule 7: a domain target (telar_add_domain) declares in DEPS exactly the domains of its
    process that its files import: the module interfaces below its folder and its sources.
    A DEPS entry names a lower domain of `process_layers`, since the target links it; a domain
    imported but missing from DEPS builds only while another dependency happens to bring it,
    and one declared but not imported relinks the target for nothing. DEPS entries that name
    a target rather than a domain (telar::config) are not checked. A domain may be a nested
    folder (`features/terminal/links`); EXCLUDE leaves out the folders below it that are
    domains of their own."""
    errors, count = [], 0
    for path in sorted(name for name in files if name.endswith('CMakeLists.txt')):
        for process, domain, arguments in domain_declarations(path, read(path)):
            count += 1
            folder = f'src/{process}/{domain}'
            where = f'{path}: telar_add_domain({process} {domain})'
            if path != f'{folder}/CMakeLists.txt':
                errors.append(f'{where} belongs in {folder}/CMakeLists.txt')
                continue
            order = [name for name in layers.get(process, []) if name != 'tests']
            if domain not in order:
                errors.append(f'{where} names no domain of process_layers')
                continue

            declared = [name for name in arguments.get('DEPS', []) if re.fullmatch(r'[a-z0-9_]+(/[a-z0-9_]+)*', name)]
            for name in declared:
                if name not in order:
                    errors.append(f'{where} depends on {name}, which is no domain of {process}')
                elif order.index(name) >= order.index(domain):
                    errors.append(f'{where} depends on {name}, which is not below {domain} in process_layers')

            excluded = tuple(f'{folder}/{name}/' for name in arguments.get('EXCLUDE', []))
            compiled = [name for name in files if name.startswith(folder + '/') and name.endswith('.cppm')
                        and not UNBUILT_FOLDER_RE.search(name[len(folder):]) and not name.startswith(excluded)]
            compiled += [f'{folder}/{name}' for keyword in DOMAIN_FILES for name in arguments.get(keyword, [])
                         if '$' not in name]
            imported = {}
            for source in sorted(set(compiled)):
                text = COMMENTS_RE.sub('', read(source))
                declaration = DECLARATION_RE.search(text)
                for name in imports_of(declaration[2] if declaration else '', text):
                    owner = component(name, layers)
                    if owner.startswith(f'{process}/') and owner != f'{process}/{domain}':
                        imported.setdefault(owner[len(process) + 1:], f'{source} imports {name}')
            for name in sorted(imported.keys() - set(declared), key=order.index):
                errors.append(f'{where} does not depend on {name}, but {imported[name]}')
            for name in sorted(set(declared) - imported.keys()):
                errors.append(f'{where} depends on {name}, which none of its files imports')
    if errors:
        raise RuntimeError('Domain targets against their imports:\n  ' + '\n  '.join(errors))

    return count


COMMENTS_RE = re.compile(r'//[^\n]*|/\*.*?\*/', re.S)
DECLARATION_RE = re.compile(r'^[ \t]*(export[ \t]+)?module[ \t]+([A-Za-z_][\w.]*)(?::([A-Za-z_][\w.]*))?[ \t]*;', re.M)


def module_folder(name):
    """The folder of a module is its name: telar.base.memory lives in lib/base/memory."""
    parts = name.split('.')
    if parts[0] != 'telar' or len(parts) < 2 or parts[1] in PROCESSES and len(parts) < 3:
        return None
    if parts[1] in PROCESSES:
        return PurePosixPath(PROCESSES[parts[1]], *parts[2:])
    return PurePosixPath('lib', *parts[1:])


def expected_paths(path, exported, name, partition):
    """Where a unit of `name` may live. The interface and each partition have one path; an
    implementation unit keeps its file name in the module folder or in its linux/ or macos/ folder."""
    folder = module_folder(name)
    if folder is None:
        return None
    last = name.rsplit('.', 1)[-1]
    source = PurePosixPath(path)
    if partition:
        return [folder / f'{last}-{partition}{source.suffix}']
    if exported:
        return [folder / f'{last}.cppm']
    return [folder / source.name, *(folder / platform / source.name for platform in PLATFORMS)]


def check_module_paths(files):
    """Rule 1: the path is the module name. Every unit lives in the folder of the module it
    declares, so no folder holds a unit of another module."""
    errors = []
    for path in sorted(name for name in files if name.endswith(('.cppm', '.cpp'))):
        match = DECLARATION_RE.search(COMMENTS_RE.sub('', (ROOT / path).read_text(errors='replace')))
        if not match:
            if path.endswith('.cppm'):
                errors.append(f'{path} declares no module')
            continue
        exported, name, partition = bool(match[1]), match[2], match[3]
        expected = expected_paths(path, exported, name, partition)
        if expected is None:
            errors.append(f'{path} declares {name}, which names no folder')
        elif PurePosixPath(path) not in expected:
            unit = f'{name}:{partition}' if partition else name
            errors.append(f'{path} declares {unit}; it belongs in {expected[0]}')
    if errors:
        raise RuntimeError('Module units outside the folder of their module:\n  ' + '\n  '.join(errors))


def owned_units(files):
    return sorted(name for name in files if name.endswith(('.cppm', '.cpp'))
                  and not re.search(r'/(tests|tools)/', name) and global_fragment((ROOT / name).read_text()))


def check_header_owners(owners, units):
    """A header an owner module re-exports stays out of every other global fragment.

    Each module that includes it textually would carry its own copy of the header's
    declarations, and importers would merge those copies again. No global fragment, an
    owner's included, names a C++ library header: the owned headers reach it on their own.
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
        fragment = global_fragment((ROOT / unit).read_text())
        for spelling in INCLUDE_RE.findall(fragment):
            header = resolve(unit, spelling)
            if header in owner_of and owner_of[header] != unit:
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


SOURCE_SUFFIXES = ('.cppm', '.cpp', '.hpp', '.h', '.inc', '.c', '.m', '.mm')
# C and Objective-C(++) cannot import C++ modules.
FOREIGN_SUFFIXES = ('.c', '.m', '.mm')
QT_INCLUDE_RE = re.compile(r'^\s*#\s*include\s*<Qt?[A-Z]', re.M)
ANY_INCLUDE_RE = re.compile(r'^\s*#\s*include\b\s*(<[^>\n]*>|"[^"\n]*"|\w+)', re.M)


def includes_of(text):
    """The spellings a file includes: `<string>` keeps its brackets, a quoted path drops its quotes."""
    return {spelling.strip('"') for spelling in ANY_INCLUDE_RE.findall(text)}


UNIT_MODULE_RE = re.compile(r'^(?:export )?module ([\w.]+)(?::[\w.]+)?;', re.M)


def module_of(text):
    """The module a unit belongs to, its partitions included; None outside a named module."""
    match = UNIT_MODULE_RE.search(text)
    return match[1] if match else None


def unit_modules(files, owners):
    """The module each source belongs to: the one a unit declares, and for a header listed in
    `owners` the module of its owner interface, since only that module includes it."""
    modules = {name: module_of((ROOT / name).read_text(errors='replace'))
               for name in files if name.endswith(SOURCE_SUFFIXES)}
    for owner, headers in owners.items():
        modules.update({header: modules.get(owner) for header in headers})

    return modules


def qt_adapters(sources):
    """The sources that include a `<Q…>` header, directly or through the project headers they
    include. A unit that defines members of a class declared in a Qt header compiles Qt textually
    whether or not it names a Qt type itself."""
    includes, qt, pending = {}, set(), list(sources)
    while pending:
        name = pending.pop()
        if name in includes:
            continue

        text = sources.get(name) or (ROOT / name).read_text(errors='replace')
        includes[name] = {header for header in (resolve(name, s) for s in includes_of(text)) if header}
        pending += includes[name]
        if QT_INCLUDE_RE.search(text):
            qt.add(name)

    while found := {name for name, headers in includes.items() if name not in qt and headers & qt}:
        qt |= found

    return qt


def textual_include_sites(files, macro_headers, owners, libraries, modules):
    """The includes rule 5 does not excuse, by file.

    lib/sys, Qt/moc adapters (qt_adapters) and C or Objective-C(++) sources may include, and so
    may the headers they reach: those headers stay textual because they cannot import. An owner
    module may include the headers it owns that cross that boundary, and the units of the module
    that `libraries` names for a third-party header may include it, the headers that module owns
    included. Any file may include a macro header or a generated `.inc` data fragment, which the
    build writes outside the tree. Tests, tools and OUTSIDE_RULE_5 are out of the rule.
    """
    sources = {name: (ROOT / name).read_text(errors='replace') for name in files
               if name.endswith(SOURCE_SUFFIXES) and not name.startswith(OUTSIDE_RULE_5)
               and not re.search(r'/(tests|tools)/', name)}
    qt = qt_adapters(sources)
    reached = set()
    pending = [name for name in sources
               if name.startswith('lib/sys/') or name.endswith(FOREIGN_SUFFIXES) or name in qt]
    while pending:
        name = pending.pop()
        if name in reached:
            continue

        reached.add(name)
        text = sources.get(name) or (ROOT / name).read_text(errors='replace')
        pending += [header for header in (resolve(name, s) for s in includes_of(text)) if header]

    def excused(unit, spelling):
        if spelling in libraries:
            return modules.get(unit) == libraries[spelling]

        header = resolve(unit, spelling)
        if header is None and spelling.endswith('.inc') and not spelling.startswith('<'):
            return True

        return header in macro_headers or header in reached and header in owners.get(unit, ())

    sites = {}
    for name, text in sources.items():
        if name in reached:
            continue

        spellings = {spelling for spelling in includes_of(text) if not excused(name, spelling)}
        if spellings:
            sites[name] = spellings

    return sites


def check_includes(files, allowed, macro_headers, owners, libraries):
    """Rule 5: no #include outside the exceptions. docs/build/textual-includes.json lists, by
    file, the includes that exist today; the change that removes one removes its entry.
    `macro_headers` lists the project's macro headers, which include nothing themselves.
    `libraries` maps each third-party header to the one module whose units include it."""
    errors = []

    modules = unit_modules(files, owners)
    included = {(module, spelling) for name, module in modules.items() if module
                for spelling in includes_of((ROOT / name).read_text(errors='replace'))}
    errors += [f'{owner} owns {spelling} but does not include it'
               for spelling, owner in sorted(libraries.items()) if (owner, spelling) not in included]

    for header in macro_headers:
        if header not in files:
            errors.append(f'macro header {header} does not exist')
        elif includes_of((ROOT / header).read_text()):
            errors.append(f'macro header {header} includes other headers')

    sites = textual_include_sites(files, set(macro_headers), owners, libraries, modules)

    for name in sorted(sites.keys() | allowed.keys()):
        found, listed = sites.get(name, set()), set(allowed.get(name, ()))
        errors += [f'{name} includes {spelling}' for spelling in sorted(found - listed)]
        errors += [f'{name} no longer includes {spelling}; remove it from textual-includes.json'
                   for spelling in sorted(listed - found)]
    if errors:
        raise RuntimeError('Includes outside the exceptions of rule 5:\n  ' + '\n  '.join(errors))

    return sum(len(spellings) for spellings in sites.values())


TOKEN_RE = re.compile(r'''
    //[^\n]*|/\*.*?\*/
  | ^[ \t]*\#(?:\\\n|[^\n])*
  | (?P<literal>(?:u8|[uUL])?R"(?P<delimiter>[^(\s]*)\(.*?\)(?P=delimiter)"
      | (?:u8|[uUL])?"(?:\\.|[^"\\\n])*"|(?:u8|[uUL])?'(?:\\.|[^'\\\n])*')
  | (?P<number>\d[\w.']*)
  | (?P<token>[A-Za-z_]\w*|::|->|\S)
''', re.S | re.M | re.X)


@functools.cache
def tokens(text):
    """The code tokens of a unit: comments and directives dropped, literals reduced to placeholders.
    Rule 4 and the declarations of rule 6 read the same interfaces, so each is tokenized once; the
    list is shared and nobody modifies it."""
    found = []
    for match in TOKEN_RE.finditer(text):
        if match['literal']:
            found.append('""')
        elif match['number']:
            found.append('0')
        elif match['token']:
            found.append(match['token'])

    return found


def reexports_of(text):
    """The modules a unit re-exports. `export import :p` is left out: the standard needs it for
    a primary interface to export its own partition."""
    found = [';'] + tokens(text) + [';']

    return {''.join(found[index + 1:found.index(';', index)])
            for index, token in enumerate(found)
            if token == 'import' and found[index - 1] == 'export' and found[index + 1] != ':'}


def check_reexports(sources, allowed):
    """Rule 4: no `export import` but that of an own partition, std included. Each file imports
    the modules it names, so its imports show every dependency it really has. Tests and tools
    are in the rule too. docs/build/reexports.json lists, by file, the re-exports that exist
    today; the change that removes one removes its entry. `sources` maps each interface to its
    text."""
    sites = {}
    for name, text in sorted(sources.items()):
        targets = reexports_of(text)
        if targets:
            sites[name] = targets

    errors = []
    for name in sorted(sites.keys() | allowed.keys()):
        found, listed = sites.get(name, set()), set(allowed.get(name, ()))
        errors += [f'{name} re-exports {target}; import it where it is named instead'
                   for target in sorted(found - listed)]
        errors += [f'{name} no longer re-exports {target}; remove it from reexports.json'
                   for target in sorted(listed - found)]
    if errors:
        raise RuntimeError('Re-exports against rule 4:\n  ' + '\n  '.join(errors))

    return sum(len(targets) for targets in sites.values())



UNUSED_IMPORTS = 'docs/build/unused-imports.json'
IMPORTING_SUFFIXES = ('.cppm', '.cpp', '.hpp', '.h')
CLASS_KEYS = {'class', 'struct', 'union', 'enum'}
# A declaration ends its head at the first of these outside angle brackets.
TERMINATORS = {'(', '=', '{', ';', '[', ','}
# Their parentheses hold an expression or a type, not the parameters of the name before them.
SPECIFIER_CALLS = {'alignas', 'decltype', 'noexcept', 'requires', 'explicit', '__attribute__', '__declspec'}
KEYWORDS = set('''alignas alignof and asm auto bool break case catch char char8_t char16_t char32_t class
co_await co_return co_yield concept const consteval constexpr constinit const_cast continue decltype
default delete do double dynamic_cast else enum explicit export extern false final float for friend goto
if import inline int long module mutable namespace new noexcept not nullptr operator or override private
protected public register reinterpret_cast requires return short signed sizeof static static_assert
static_cast struct switch template this thread_local throw true try typedef typeid typename union
unsigned using virtual void volatile wchar_t while'''.split())


def identifier(token):
    return (token[0].isalpha() or token[0] == '_') and token not in KEYWORDS


def closing_braces(found):
    """The index of the `}` that closes each `{`."""
    closing, pending = {}, []
    for index in [index for index, token in enumerate(found) if token == '{' or token == '}']:
        if found[index] == '{':
            pending.append(index)
        elif pending:
            closing[pending.pop()] = index

    return closing


def skip_group(found, index, closing):
    """The index after the group that opens at `index`: parentheses, brackets or braces."""
    if found[index] == '{':
        return closing.get(index, len(found) - 1) + 1

    depth = 0
    while index < len(found):
        token = found[index]
        if token == '{':
            index = closing.get(index, len(found) - 1)
        elif token == '(' or token == '[':
            depth += 1
        elif token == ')' or token == ']':
            depth -= 1
            if depth == 0:
                return index + 1

        index += 1

    return index


def skip_angles(found, index, closing):
    """The index after the template argument or parameter list that opens at `index`."""
    depth = 0
    while index < len(found):
        token = found[index]
        if token in ('(', '[', '{'):
            index = skip_group(found, index, closing)
            continue

        if token == '<':
            depth += 1
        elif token == '>':
            depth -= 1
            if depth == 0:
                return index + 1
        elif token == ';':
            return index

        index += 1

    return index


def statement_end(found, index, closing):
    """The index after the `;` that ends the declaration running at `index`."""
    while index < len(found) and found[index] != ';':
        if found[index] in ('(', '[', '{'):
            index = skip_group(found, index, closing)
        else:
            index += 1

    return index + 1


def name_before(found, index):
    """The unqualified name that ends right before `index`, its template arguments skipped; None
    for a qualified name, which defines something declared before."""
    index -= 1
    if found[index] == '>':
        depth = 0
        while index > 0:
            depth += {'>': 1, '<': -1}.get(found[index], 0)
            if depth == 0:
                break

            index -= 1

        index -= 1

    if index < 0 or not identifier(found[index]) or found[index - 1] in ('::', '~', '.', '->'):
        return None

    return found[index]


def function_end(found, index, closing):
    """The index after a function declaration whose parameters open at `index`: its `;`, or
    the body that follows a constructor's member initializers."""
    index = skip_group(found, index, closing)
    initializers = False
    while index < len(found):
        token = found[index]
        if token == ';':
            return index + 1
        if token == '{':
            if not initializers or found[index - 1] in (')', '}'):
                return skip_group(found, index, closing)
        elif token == ':':
            initializers = True
        elif token == '(' or token == '[':
            index = skip_group(found, index, closing)
            continue

        index += 1

    return index


def class_declaration(found, index, closing, names):
    """Read the class, union or enum whose key is at `index`: its name and, for an enum, its
    enumerators. A class key that only elaborates the type of a function hands over to it."""
    enum = found[index] == 'enum'
    index += 1
    if enum and found[index] in ('class', 'struct'):
        index += 1
    while found[index] == '[' or found[index] in SPECIFIER_CALLS:
        index = skip_group(found, index + (found[index] != '['), closing)
    # Annotation macros such as TBC_SHARED stand between the key and the name.
    while identifier(found[index]) and identifier(found[index + 1]):
        index += 1
    if identifier(found[index]) and found[index + 1] != '::':
        names.append(found[index])

    while index < len(found):
        token = found[index]
        if token == ';':
            return index + 1
        if token == '<':
            index = skip_angles(found, index, closing)
            continue

        if token == '(':
            name = name_before(found, index)
            if name:
                names.append(name)

            return function_end(found, index, closing)
        if token == '{':
            body = skip_group(found, index, closing)
            if enum:
                names += enumerators(found, index, body - 1, closing)

            return statement_end(found, body, closing)
        index += 1

    return index


def enumerators(found, start, end, closing):
    """The enumerators of the enum body between the braces at `start` and `end`."""
    names, index, expecting = [], start + 1, True
    while index < end:
        token = found[index]
        if token in ('(', '[', '{'):
            index = skip_group(found, index, closing)
            continue

        if expecting and identifier(token):
            names.append(token)
        expecting = token == ','
        index += 1

    return names


def declaration(found, index, closing):
    """The index after the namespace-scope declaration at `index` and the names it declares:
    types, functions, variables, concepts and aliases. Class members, parameters, locals,
    operators and qualified definitions are left out."""
    while found[index] == 'template':
        index += 1
        if found[index] == '<':
            index = skip_angles(found, index, closing)

    first = found[index]
    if first == 'using':
        end = statement_end(found, index, closing)
        if found[index + 1] in ('namespace', 'enum'):
            return end, []
        if found[index + 2] == '=':
            return end, [found[index + 1]]

        # A using-declaration declares the last component of the name it qualifies.
        return end, [found[end - 2]] if identifier(found[end - 2]) else []
    if first == 'typedef':
        end = statement_end(found, index, closing)
        head = found[index:end]
        pointer = [head[at + 2] for at in range(len(head) - 3) if head[at] == '(' and head[at + 1] == '*']
        name = pointer[0] if pointer else name_before(found, end - 1)
        return end, [name] if name and identifier(name) else []
    if first == 'concept':
        return statement_end(found, index, closing), [found[index + 1]]

    names, angles = [], 0
    while index < len(found):
        token = found[index]
        if token == '[' and found[index + 1] == '[':
            index = skip_group(found, index, closing)
            continue

        if token in SPECIFIER_CALLS and found[index + 1] == '(':
            index = skip_group(found, index + 1, closing)
            continue

        if token == 'operator':
            index += 3 if found[index + 1] == '(' else 1
            while index < len(found) and found[index] not in ('(', ';'):
                index += 1

            if found[index] == ';':
                return index + 1, []
            return function_end(found, index, closing), []
        if token == '<':
            angles += 1
        elif token == '>':
            angles = max(angles - 1, 0)
        elif angles == 0 and token in CLASS_KEYS:
            return class_declaration(found, index, closing, names), names
        elif angles == 0 and token in TERMINATORS:
            break
        index += 1

    if index >= len(found):
        return index, []

    name = name_before(found, index)
    if name:
        names.append(name)
    if found[index] == '(':
        return function_end(found, index, closing), names

    return statement_end(found, index, closing), names


# An X-macro list, `#define LIST(X) X(a) X(b) LIST2(X)`: an interface that expands it at namespace
# scope declares a, b and what LIST2 lists. The tokens drop directives, so its items come from here.
MACRO_LIST_RE = re.compile(r'^[ \t]*\#[ \t]*define[ \t]+(\w+)\([ \t]*(\w+)[ \t]*\)((?:\\\n|[^\n])*)', re.M)
MACRO_ITEM_RE = re.compile(r'(\w+)\s*\(\s*(\w+)\s*\)')


def macro_lists(text):
    """The X-macro lists a unit defines, each with the names it expands to."""
    lists = {}
    for name, parameter, body in MACRO_LIST_RE.findall(text):
        items = MACRO_ITEM_RE.findall(body)
        if items and all(parameter in item for item in items) and not MACRO_ITEM_RE.sub('', body).replace('\\', '').strip():
            lists[name] = [(macro == parameter, argument if macro == parameter else macro) for macro, argument in items]

    def expand(name, seen):
        names = []
        for direct, value in lists[name]:
            if direct:
                names.append(value)
            elif value in lists and value not in seen:
                names += expand(value, seen | {name})

        return names

    return {name: expand(name, {name}) for name in lists}


def declarations(found, lists={}):
    """What a module unit declares at namespace scope, from its tokens: the names it exports,
    every name it declares, and its namespaces. `lists` holds the unit's X-macro lists
    (macro_lists), whose expansion declares their items."""
    exported, every, namespaces = set(), set(), set()
    closing = closing_braces(found)
    scopes, index = [], 0
    while index < len(found):
        token = found[index]
        if token == '}':
            if scopes:
                scopes.pop()
            index += 1
            continue

        if token == ';':
            index += 1
            continue

        exporting = bool(scopes) and scopes[-1]
        if token == 'export':
            exporting = True
            index += 1
            token = found[index] if index < len(found) else ';'
        if token == '{':
            scopes.append(exporting)
            index += 1
            continue

        if token in ('module', 'import'):
            index = statement_end(found, index, closing)
            continue

        if token == 'inline' and found[index + 1] == 'namespace':
            index += 1
            token = 'namespace'
        if token == 'namespace':
            end = index + 1
            while end < len(found) and found[end] not in ('{', '=', ';'):
                end += 1

            if found[end] == '{':
                namespaces.update(name for name in found[index + 1:end] if name != '::')
                scopes.append(exporting)
                index = end + 1
            else:
                namespaces.add(found[index + 1])
                index = statement_end(found, end, closing)
            continue

        if token == 'extern' and found[index + 1] == '""' and found[index + 2] == '{':
            scopes.append(exporting)
            index += 3
            continue

        if token in lists and found[index + 1] == '(':
            index, names = skip_group(found, index + 1, closing), lists[token]
        else:
            index, names = declaration(found, index, closing)
        every.update(names)
        if exporting:
            exported.update(names)

    return exported, every, namespaces


def exported_namespaces(found):
    """The namespaces in which a module unit exports a declaration, as `a::b`, from its tokens."""
    closing = closing_braces(found)
    scopes, used, index = [], set(), 0
    while index < len(found):
        token = found[index]
        if token == '}':
            if scopes:
                scopes.pop()
            index += 1
            continue

        if token == ';':
            index += 1
            continue

        exporting = bool(scopes) and scopes[-1][0]
        path = [name for _, name in scopes if name]
        if token == 'export':
            exporting = True
            index += 1
            token = found[index] if index < len(found) else ';'
        if token == '{':
            scopes.append((exporting, None))
            index += 1
            continue

        if token in ('module', 'import'):
            index = statement_end(found, index, closing)
            continue

        if token == 'inline' and found[index + 1] == 'namespace':
            index += 1
            token = 'namespace'
        if token == 'namespace':
            end = index + 1
            while end < len(found) and found[end] not in ('{', '=', ';'):
                end += 1

            if found[end] == '{':
                scopes.append((exporting, '::'.join(name for name in found[index + 1:end] if name != '::')))
                index = end + 1
            else:
                index = statement_end(found, end, closing)
            continue

        if token == 'extern' and found[index + 1] == '""' and found[index + 2] == '{':
            scopes.append((exporting, None))
            index += 3
            continue

        index, names = declaration(found, index, closing)
        if exporting and names:
            used.add('::'.join(path))

    return used


def module_namespace(name, roots):
    """The namespace a module exports into when its folder is below one of `roots`: its folder
    below the process, `telar.gui.features.history` exporting into telar::gui::features::history."""
    folder = module_folder(name.split(':')[0])
    if folder is None or not any(str(folder) == root or str(folder).startswith(root + '/') for root in roots):
        return None
    parts = name.split(':')[0].split('.')
    return '::'.join(parts)


def check_module_namespaces(files, roots, read):
    """Rule 8: a module below a folder of `namespaced_folders` exports into the namespace its name
    spells, `telar.gui.features.history` into telar::gui::features::history (or a namespace
    below it), so the import, the folder and the qualified names say the same thing."""
    errors, count = [], 0
    for path in sorted(name for name in files if name.endswith('.cppm')):
        text = read(path)
        match = DECLARATION_RE.search(COMMENTS_RE.sub('', text))
        if not match or not match[1]:
            continue
        expected = module_namespace(match[2], roots)
        if expected is None:
            continue
        count += 1
        for used in sorted(exported_namespaces(tokens(text))):
            if used != expected and not used.startswith(expected + '::'):
                errors.append(f'{path} exports into {used or "the global namespace"}; {match[2]} exports into {expected}')
    if errors:
        raise RuntimeError('Modules exporting outside the namespace of their name:\n  ' + '\n  '.join(errors))

    return count


def provided_names(sources, interfaces, reexports, implicit):
    """For each module and each partition, the names whose use makes an import of it needed,
    as bytes, and its namespaces. A module provides what its interface units export, a
    partition what it declares, and both what reaches them through the re-exports still listed
    in reexports.json. `implicit` (`implicit_uses` in modules.json) adds the names a module
    serves without declaring them: the types its specializations and ADL functions apply to,
    and the macros whose expansion names it."""
    own = {}
    for source, text in sources.items():
        exported, every, namespaces = declarations(tokens(text), macro_lists(text))
        module = interfaces[source]
        primary = module.split(':')[0]
        own.setdefault(primary, [set(), set(), set()])
        own[primary][0] |= exported
        own[primary][2] |= namespaces
        if ':' in module:
            own[module] = [every, set(), namespaces]
        own[primary][1].update(target for target in reexports.get(source, ()) if target != 'std')
        if module != primary:
            own[module][1].update(target for target in reexports.get(source, ()) if target != 'std')

    errors = []
    for entry in implicit:
        if entry.get('module') not in own or not entry.get('names') or not entry.get('reason'):
            errors.append(f'implicit use {entry} needs a known module, the names it applies to and a reason')
        else:
            own[entry['module']][0].update(entry['names'])
    if errors:
        raise RuntimeError('Invalid implicit uses in modules.json:\n  ' + '\n  '.join(errors))

    provided = {}

    def provide(module):
        if module not in provided:
            names, targets, namespaces = own[module]
            provided[module] = (set(names), set(namespaces))
            for target in targets:
                if target in own:
                    reached, spaces = provide(target)
                    provided[module][0].update(reached)
                    provided[module][1].update(spaces)

        return provided[module]

    for module in own:
        provide(module)

    # A namespace that only one module declares names that module when it qualifies a name, as
    # `cell_layout::wide`, whose declaration the checker may not see; unit_names spells such a
    # use `cell_layout::`.
    owners = collections.Counter(space for module, (_, _, spaces) in own.items() if ':' not in module for space in spaces)
    for names, spaces in provided.values():
        names.update(space + '::' for space in spaces if owners[space] == 1)

    return {module: (frozenset(name.encode() for name in names), frozenset(name.encode() for name in spaces))
            for module, (names, spaces) in provided.items()}


# Comments, literals and the header names of includes, which name nothing. A character literal
# holds an escape or up to four characters, so that the separators of 10'000 cannot open one
# that swallows the code up to the next quote. Each branch starts with a fixed character: an
# encoding prefix (u8, u, U, L) stays behind as a name of its own, because matching it here
# would make `re` try the pattern at every u, U and L of the text, seven times slower.
UNIT_JUNK_RE = re.compile(rb'''//[^\n]*|/\*.*?\*/|R"([^(\s]*)\(.*?\)\1"|"(?:\\.|[^"\\\n])*"
  |'(?:\\.[^'\\\n]*|[^'\\\n]{1,4})'|\#[ \t]*include[ \t]*<[^>\n]*>''', re.S | re.X)
UNIT_DECLARATION_RE = re.compile(rb'^[ \t]*(?:export[ \t]+)?(?:import|module)\b[^;]*;', re.M)
UNIT_IMPORT_RE = re.compile(rb'^[ \t]*(export[ \t]+)?import[ \t]+([\w.:]+)[ \t]*;', re.M)
UNIT_MODULE_BYTES_RE = re.compile(rb'^[ \t]*(?:export[ \t]+)?module[ \t]+([\w.]+)(?::[\w.]+)?[ \t]*;', re.M)
# A namespace is named by itself in a using-directive and in an alias; elsewhere it only
# qualifies another name, and every module declares `telar`.
NAMESPACE_USE_RE = re.compile(rb'namespace\s+(?:\w+\s*=\s*)?([\w:\s]+);')
IDENTIFIER_BYTES = bytes(byte if chr(byte).isascii() and (chr(byte).isalnum() or byte == ord('_')) else 32
                         for byte in range(256))
# The identifiers with their colons, so that a qualified name reads as one token.
QUALIFIED_BYTES = bytes(byte if byte == ord(':') else IDENTIFIER_BYTES[byte] for byte in range(256))


def unit_names(text):
    """What a unit names outside comments and literals, each qualifier also as `name::`, the
    namespaces it names by themselves, the modules it imports without re-exporting them, as
    spelled, and its module."""
    if b'import' not in text:
        return set(), set(), set(), None

    text = UNIT_JUNK_RE.sub(b' ', text)
    # Imports and the module declaration precede the code; their names are not uses.
    end = text.find(b';', text.rfind(b'import')) + 1
    preamble, code = text[:end], text[end:]
    imports = {match[2] for match in UNIT_IMPORT_RE.finditer(preamble) if not match[1]}
    module = UNIT_MODULE_BYTES_RE.search(preamble)
    names = set(UNIT_DECLARATION_RE.sub(b' ', preamble).translate(IDENTIFIER_BYTES).split())
    names.update(code.translate(IDENTIFIER_BYTES).split())
    names.update(qualifier + b'::' for token in code.translate(QUALIFIED_BYTES).split() if b'::' in token
                 for qualifier in token.split(b'::')[:-1] if qualifier)
    namespaces = {match.split(b'::')[-1].strip() for match in NAMESPACE_USE_RE.findall(code)}

    return names, namespaces, imports, module[1] if module else None


def unused_import_sites(units, provided):
    """The imports of each unit that name nothing their module provides, as spelled. `units`
    maps each file to its bytes. std is left out, and so is a module the inventory does not
    know: the checker cannot tell what it declares."""
    sites = {}
    for name, text in units.items():
        names, namespaces, imports, module = unit_names(text)
        for spelling in imports:
            target = (module or b'') + spelling if spelling.startswith(b':') else spelling
            found = provided.get(target.decode())
            if spelling == b'std' or found is None:
                continue

            if found[0].isdisjoint(names) and found[1].isdisjoint(namespaces):
                sites.setdefault(name, set()).add(spelling.decode())

    return sites


def write_unused_imports(sites):
    (ROOT / UNUSED_IMPORTS).write_text(
        json.dumps({name: sorted(found) for name, found in sorted(sites.items())}, indent=2) + '\n')


def check_unused_imports(units, provided, allowed):
    """Rule 6: a unit imports only the modules it uses. An import is used when the unit names,
    outside comments and literals, something the module provides (provided_names). Tests and
    tools are in the rule too. docs/build/unused-imports.json lists, by file, the unused imports
    that exist today; the change that removes one removes its entry, and
    `--write-unused-imports` rewrites the list after changes that move imports."""
    sites = unused_import_sites(units, provided)
    errors = []
    for name in sorted(sites.keys() | allowed.keys()):
        found, listed = sites.get(name, set()), set(allowed.get(name, ()))
        errors += [f'{name} imports {target} but names nothing it provides; remove the import'
                   for target in sorted(found - listed)]
        errors += [f'{name} no longer has an unused import of {target}; remove it from unused-imports.json'
                   for target in sorted(listed - found)]
    if errors:
        raise RuntimeError('Imports against rule 6:\n  ' + '\n  '.join(errors))

    return sum(len(targets) for targets in sites.values())


if __name__ == '__main__':
    main()
