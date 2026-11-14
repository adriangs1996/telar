#!/usr/bin/env python3
"""Check module ownership and paths, import cycles and the documented textual boundaries."""
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
        graph[name] = imports_of(name, text)
        if '#include' in text and not text.startswith('module;'):
            raise RuntimeError('Textual dependencies need a global fragment: ' + source)
    check_module_paths(owned)
    imports = unit_imports(owned, graph)
    check_library_layers(inventory['library_layers'], inventory['interfaces'], imports)
    upward = check_process_layers(inventory['process_layers'], inventory['upward_imports'], imports)
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
    allowed = json.loads((ROOT / 'docs/build/textual-includes.json').read_text())
    includes = check_includes(owned, allowed, inventory['macro_headers'], inventory['header_owners'])
    owned = check_header_owners(inventory['header_owners'], owned_units(owned))
    reexports = check_reexports(inventory['interfaces'],
                                json.loads((ROOT / 'docs/build/reexports.json').read_text()))
    print(f'{len(graph)} module interfaces, acyclic imports, {upward} upward imports left, '
          f'{len(headers)} justified textual boundaries, {includes} textual includes left, '
          f'{owned} headers reached only through their owner module, '
          f'{reexports} re-exports without a type left')


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


def component(name):
    """`lib/<library>` for a library module, `<process>/<top folder>` for a process module."""
    parts = name.split(':')[0].split('.')

    return f'{parts[1]}/{parts[2]}' if parts[1] in PROCESSES else f'lib/{parts[1]}'


def check_process_layers(layers, allowed, imports):
    """Rule 2: a module imports only downward. Libraries sit below every process, and
    `process_layers` in modules.json orders the components of each process, lowest first. A
    process reaches only libraries and its own components. `upward_imports` lists the upward
    imports that exist today; the change that removes one removes its entry."""
    position = {f'{process}/{folder}': index
                for process, folders in layers.items() for index, folder in enumerate(folders)}
    unplaced = {component(name) for name in imports} - position.keys()
    unplaced = sorted(name for name in unplaced if not name.startswith('lib/'))
    if unplaced:
        raise RuntimeError('Place each component in process_layers: ' + ', '.join(unplaced))

    def downward(source, target):
        upper, lower = component(source), component(target)
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


SOURCE_SUFFIXES = ('.cppm', '.cpp', '.hpp', '.h', '.inc', '.c', '.m', '.mm')
# C and Objective-C(++) cannot import C++ modules.
FOREIGN_SUFFIXES = ('.c', '.m', '.mm')
QT_INCLUDE_RE = re.compile(r'^\s*#\s*include\s*<Qt?[A-Z]', re.M)
ANY_INCLUDE_RE = re.compile(r'^\s*#\s*include\b\s*(<[^>\n]*>|"[^"\n]*"|\w+)', re.M)


def includes_of(text):
    """The spellings a file includes: `<string>` keeps its brackets, a quoted path drops its quotes."""
    return {spelling.strip('"') for spelling in ANY_INCLUDE_RE.findall(text)}


def textual_include_sites(files, macro_headers, owners):
    """The includes rule 5 does not excuse, by file.

    lib/sys, Qt/moc adapters and C or Objective-C(++) sources may include, and so may the headers
    they reach: those headers stay textual because they cannot import. An owner module may include
    the headers it owns that cross that boundary, and any file may include a macro header. Tests
    and tools are out of the rule.
    """
    sources = {name: (ROOT / name).read_text(errors='replace') for name in files
               if name.endswith(SOURCE_SUFFIXES) and not re.search(r'/(tests|tools)/', name)}
    reached = set()
    pending = [name for name, text in sources.items()
               if name.startswith('lib/sys/') or name.endswith(FOREIGN_SUFFIXES) or QT_INCLUDE_RE.search(text)]
    while pending:
        name = pending.pop()
        if name in reached:
            continue

        reached.add(name)
        text = sources.get(name) or (ROOT / name).read_text(errors='replace')
        pending += [header for header in (resolve(name, s) for s in includes_of(text)) if header]

    def excused(unit, spelling):
        header = resolve(unit, spelling)

        return header in macro_headers or header in reached and header in owners.get(unit, ())

    sites = {}
    for name, text in sources.items():
        if name in reached:
            continue

        spellings = {spelling for spelling in includes_of(text) if not excused(name, spelling)}
        if spellings:
            sites[name] = spellings

    return sites


def check_includes(files, allowed, macro_headers, owners):
    """Rule 5: no #include outside the exceptions. docs/build/textual-includes.json lists, by
    file, the includes that exist today; the change that removes one removes its entry.
    `macro_headers` lists the project's macro headers, which include nothing themselves."""
    errors = []

    for header in macro_headers:
        if header not in files:
            errors.append(f'macro header {header} does not exist')
        elif includes_of((ROOT / header).read_text()):
            errors.append(f'macro header {header} includes other headers')

    sites = textual_include_sites(files, set(macro_headers), owners)

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
IDENTIFIER_RE = re.compile(r'[A-Za-z_]\w*')
TYPE_KEYWORDS = {'class', 'struct', 'union', 'enum', 'concept'}
# What may follow the name a type declaration introduces; `<` would be a specialization.
DECLARED_FOLLOWERS = {'{', ';', ':', 'final', '='}
FUNCTION_QUALIFIERS = {'const', 'noexcept', 'override', 'final', 'mutable', 'volatile', '&'}
TRAILING_RETURN_RE = re.compile(r'[A-Za-z_]\w*|::|<|>|,|\*|&|0')


def tokens(text):
    """The code tokens of a unit: comments and directives dropped, literals reduced to placeholders."""
    found = []
    for match in TOKEN_RE.finditer(text):
        if match['literal']:
            found.append('""')
        elif match['number']:
            found.append('0')
        elif match['token']:
            found.append(match['token'])

    return found


def skip_balanced(found, index, opening, closing):
    """The index right after the bracket that closes the one at `index`."""
    depth = 0
    while index < len(found):
        depth += (found[index] == opening) - (found[index] == closing)
        index += 1
        if depth == 0:
            break

    return index


def function_body(found, index, scopes):
    """Whether the brace at `index` opens a function body: it follows a parameter list, a
    trailing return type or, inside a class, a member initializer list."""
    before = index - 1
    while found[before] in FUNCTION_QUALIFIERS:
        before -= 1
    if found[before] == ')':
        return True
    if found[before] == '}':
        return bool(scopes) and scopes[-1][0] != 'namespace'

    while TRAILING_RETURN_RE.fullmatch(found[before]) and found[before] not in TYPE_KEYWORDS:
        before -= 1

    return found[before] == '->'


def declared_type(found, index):
    """The name a type declaration starting at the keyword at `index` introduces, if any."""
    if found[index - 1] in ('<', ',', 'friend', 'using', 'typename'):
        return None

    index += 1
    # TBC_HOT_PATH stands where a class attribute does.
    while found[index] in ('class', 'struct', 'alignas', '[', 'TBC_HOT_PATH'):
        if found[index] == '[':
            index = skip_balanced(found, index, '[', ']')
        elif found[index] == 'alignas':
            index = skip_balanced(found, index + 1, '(', ')')
        else:
            index += 1
    name = found[index]

    return name if IDENTIFIER_RE.fullmatch(name) and found[index + 1] in DECLARED_FOLLOWERS else None


class Interface:
    """What rule 4 reads from the interface units of a module, outside function bodies, which
    importers never need to name."""

    def __init__(self):
        self.reexports = set()
        # Each type an exported namespace declares, or re-declares through `using`, with the
        # segments of the namespaces around it.
        self.exported = {}
        # Every type the module declares, exported or not, at any depth.
        self.declared = set()
        # The names its exported declarations mention: alone, or as (qualifier, name).
        self.unqualified = set()
        self.qualified = set()

    def names_type_of(self, target):
        """Whether these exported declarations name a type `target` exports. An unqualified name
        the module declares itself is its own type, and a qualified one has to be qualified by
        a namespace the type lives in."""
        return (any(name in target.exported for name in self.unqualified - self.declared)
                or any(qualifier in target.exported.get(name, ()) for qualifier, name in self.qualified))

    def read(self, text):
        found = tokens(text) + [';']
        start = next(index for index, token in enumerate(found)
                     if token == 'module' and found[index + 1] not in (';', ':'))
        scopes = []
        pending_export, pending_namespace = False, None
        index = found.index(';', start) + 1

        while index < len(found):
            token = found[index]
            if token == 'module' and found[index + 1:index + 3] == [':', 'private']:
                break
            if token == 'import' and found[index - 1] in (';', '{', '}', 'export'):
                end = found.index(';', index)
                if found[index - 1] == 'export':
                    self.reexports.add(''.join(found[index + 1:end]))
                index = end + 1
                pending_export = False
                continue

            exporting = pending_export or any(export for _, export, _ in scopes)
            if token == 'export':
                pending_export = True
            elif token == 'namespace':
                end = index + 1
                while IDENTIFIER_RE.fullmatch(found[end]) or found[end] == '::':
                    end += 1
                pending_namespace = [name for name in found[index + 1:end] if name != '::']
                index = end
                continue
            elif token == '{':
                if pending_namespace is not None or found[index - 1] in ('export', '""'):
                    scopes.append(('namespace', pending_export, pending_namespace or []))
                elif function_body(found, index, scopes):
                    index = skip_balanced(found, index, '{', '}')
                    pending_export = False
                    continue
                else:
                    scopes.append(('class', pending_export, []))
                pending_export, pending_namespace = False, None
            elif token == '}':
                if scopes:
                    scopes.pop()
            elif token == ';':
                pending_export, pending_namespace = False, None
            elif IDENTIFIER_RE.fullmatch(token):
                self.declare(found, index, scopes, exporting)
                if exporting:
                    self.mention(found, index)
            index += 1

    def mention(self, found, index):
        if found[index - 1] == '::' and IDENTIFIER_RE.fullmatch(found[index - 2]):
            self.qualified.add((found[index - 2], found[index]))
        else:
            self.unqualified.add(found[index])

    def declare(self, found, index, scopes, exporting):
        token = found[index]
        name = None
        if token in TYPE_KEYWORDS:
            name = declared_type(found, index)
        elif token == 'using' and found[index + 1] not in ('namespace', 'enum'):
            end = found.index(';', index)
            if found[index + 2] == '=':
                name = found[index + 1]
            # A using-declaration re-declares a type, or a function this rule leaves aside.
            elif found[end - 1][0].isupper():
                name = found[end - 1]
        elif token == 'typedef':
            name = found[found.index(';', index) - 1]
        if not name:
            return

        self.declared.add(name)
        if exporting and all(kind == 'namespace' for kind, _, _ in scopes):
            segments = self.exported.setdefault(name, set())
            segments.update(segment for _, _, names in scopes for segment in names)


def check_reexports(interfaces, allowed):
    """Rule 4: an interface re-exports a module only when its exported declarations name a type
    of that module, outside function bodies: importers need that type to use the interface, and
    anything else they import themselves. docs/build/reexports.json lists, by module, the
    re-exports that break the rule today; the change that removes one removes its entry.

    The rule reads tokens, not the AST: a type counts once its name appears where it can mean
    that type (see Interface.names_type_of)."""
    modules = {}
    for source, name in interfaces.items():
        modules.setdefault(name.split(':')[0], Interface()).read((ROOT / source).read_text())

    sites = {}
    for name, interface in sorted(modules.items()):
        for target in sorted(interface.reexports):
            if target.startswith(':') or target.split(':')[0] == name or target == 'std':
                continue
            if not interface.names_type_of(modules[target]):
                sites.setdefault(name, set()).add(target)

    errors = []
    for name in sorted(sites.keys() | allowed.keys()):
        found, listed = sites.get(name, set()), set(allowed.get(name, ()))
        errors += [f'{name} re-exports {target}, but its exported declarations name no type of it; '
                   'import it instead' for target in sorted(found - listed)]
        errors += [f'{name} no longer re-exports {target} without naming a type of it; '
                   'remove it from reexports.json' for target in sorted(listed - found)]
    if errors:
        raise RuntimeError('Re-exports against rule 4:\n  ' + '\n  '.join(errors))

    return sum(len(targets) for targets in sites.values())


if __name__ == '__main__':
    main()
