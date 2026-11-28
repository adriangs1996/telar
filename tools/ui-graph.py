#!/usr/bin/env python3
"""Measure the folder graph of src/gui/ui at a git revision and check the UI rules.

A node is a directory under ui/ at any depth (`app/chrome/activity`, `kit/scene`), so
the graph keeps measuring as the tree nests. Files directly in ui/ belong to no node.

- C++ edges come from `#include "ui/<folder>/<header>.hpp"` in .cpp, .hpp, .h and .mm files.
- QML edges come from a QML file that instantiates (`Type {`) a type whose file lives in
  another folder, or that imports a relative path (`import "../components/Fit.js"`,
  `import "../controls"`) that resolves into another folder of ui/. All QML shares one module,
  so the type name is the file name.
- A QML file that names a C++ type registered for QML in a header of another folder
  (`QML_ELEMENT` registers the class name, `QML_NAMED_ELEMENT(Name)` its argument) has a QML
  edge to that header's folder, whatever the use: instantiation, property or parameter type,
  enum or attached-property scope (`Store.Action.Copy`, `TerminalView.foo`).

The report prints how many files outside app/ include the root header, how often the shared
headers of app/ are used from outside it, and the edges and cycles of four graphs: C++ as it
is, C++ with the shared app/ headers counted as `kit`, the same without the edges to
app/ that are not shared headers (the root and U4's runtime_connection/application_effects),
and QML. `-v` lists the edges of the third graph, the files that include the root header and the
QML edges.

`--rules` checks the target rules of the UI and exits with 1 when anything breaks them:
- Every folder lives in one of three trees: app/, design/ or kit/.
- Anyone may use kit/. kit/ uses only its own subfolders.
- design/ uses only kit/ and its own subfolders. Anyone outside kit/ may use it.
- A directory of the app/ tree is reachable only from its ancestors: its parent, its parent's
  parent, up to app/ itself. Never from a sibling, a cousin or a descendant.
- Neither the C++ graph nor the QML graph has a cycle.

The revision is read with git, so no checkout is needed. Run it from anywhere in the repository:
  ui-graph.py HEAD
  ui-graph.py 1b59c8d2a -v --rules
"""
import argparse
import collections
from pathlib import Path
import posixpath
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
UI = 'src/gui/ui/'
CPP_SUFFIXES = ('.cpp', '.cppm', '.hpp', '.h', '.mm')
SOURCE_SUFFIXES = CPP_SUFFIXES + ('.qml',)
INCLUDE_RE = re.compile(r'#include\s+"ui/((?:[a-z_0-9]+/)+)([a-z_0-9]+\.hpp)"')
IMPORT_RE = re.compile(r'^\s*(?:export\s+)?import\s+telar\.gui\.ui\.([a-z_0-9]+(?:\.[a-z_0-9]+)*)\s*;', re.M)
# A quoted QML import names a directory or a script file by its path.
QML_IMPORT_RE = re.compile(r'^\s*import\s+"([^"]+)"', re.M)
# A registration macro of a C++ type for QML, with the name it gives when it names one.
QML_REGISTRATION_RE = re.compile(r'\bQML_(?:NAMED_ELEMENT\(\s*(\w+)\s*\)|ELEMENT\b)')
# A C++23 module attribute registration on a class or namespace:
#   class [[qt::object, qt::qml_element]] Foo
#   class [[qt::object, qt_qml_named("Foo")]] Bar
#   namespace [[qt::ns, qt_qml_named("Action")]] action
QT_ATTR_NAMED_RE = re.compile(r'\bqt_qml_named\(\s*"(\w+)"\s*\)')
QT_ATTR_ELEMENT_RE = re.compile(r'\b(?:class|struct)\s+\[\[[^\]]*\bqt::qml_element\b[^\]]*\]\]\s+(\w+)')
# The definition of a class, not a forward declaration: `class Name final : Base {`, `struct Name {`.
CLASS_RE = re.compile(r'\b(?:class|struct)\s+(?:[A-Z_]+\s+)?(\w+)\s*(?:final\s*)?[:{]')
# Comments and string literals of QML and JavaScript, where a type name is not a use.
QML_NON_CODE_RE = re.compile(
    r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|`(?:\\.|[^`\\])*`', re.S)
# Headers of app/ that make a file depend on ApplicationController.
ROOT_HEADERS = {'application.hpp', 'application_controller.hpp'}
# Headers of app/ that are utilities, not the root (U3). The second graph counts them as
# kit/, the third keeps them while it drops every other edge to app/.
SHARED_HEADERS = {
    'projection.hpp', 'list_model.hpp', 'deadline_timer.hpp', 'command_process.hpp', 'host_command.hpp',
    'utf16_encoding.hpp', 'window_frame_pacer.hpp', 'window_identity.hpp', 'launch_arguments.hpp',
}
# Long cycles print as their size only.
CYCLE_LISTING_LIMIT = 8
# The trees of the target layout of ui/.
TREES = ('app', 'design', 'kit')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('rev', help='git revision to read, such as HEAD or a commit')
    parser.add_argument('-v', dest='verbose', action='store_true',
                        help='list the edges without root edges and the files that include the root header')
    parser.add_argument('--rules', action='store_true',
                        help='check the target rules of the UI and exit with 1 on violations')
    arguments = parser.parse_args()

    sources = load_sources(arguments.rev, ROOT)
    lines, code = report(arguments.rev, sources, arguments.verbose, arguments.rules)
    print('\n'.join(lines))
    sys.exit(code)


def load_sources(rev, repository):
    """Return {path: text} of the C++ and QML files in the folders of ui/ at `rev`, in git order.
    A tests/ folder is no node: its tests use the folder they live in, and its parents."""
    listing = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', rev, UI],
                                      cwd=repository, text=True).split()
    paths = [path for path in listing if path.endswith(SOURCE_SUFFIXES) and '/' in path[len(UI):]
             and '/tests/' not in path[len(UI) - 1:]]
    if not paths:
        return {}

    # One git process reads every blob instead of one `git show` per file.
    request = ''.join(f'{rev}:{path}\n' for path in paths).encode()
    output = subprocess.run(['git', 'cat-file', '--batch'], cwd=repository, input=request,
                            stdout=subprocess.PIPE, check=True).stdout
    sources = {}
    offset = 0
    for path in paths:
        header_end = output.index(b'\n', offset)
        size = int(output[offset:header_end].split()[2])
        start = header_end + 1
        sources[path] = output[start:start + size].decode(errors='ignore')
        offset = start + size + 1

    return sources


def folder(path):
    """The node of a file: its directory below ui/."""
    return path[len(UI):].rsplit('/', 1)[0]


def include_edges(sources):
    """Return the C++ edges (file, folder, included folder, header) between different folders."""
    edges = []
    for path, text in sources.items():
        if not path.endswith(CPP_SUFFIXES):
            continue

        node = folder(path)
        for included, header in INCLUDE_RE.findall(text):
            included = included.rstrip('/')
            if included != node:
                edges.append((path, node, included, header))
        for imported in IMPORT_RE.findall(text):
            included = imported.replace('.', '/')
            if included != node:
                edges.append((path, node, included, imported.rsplit('.', 1)[-1] + '.cppm'))

    return edges


def imported_folder(path, imported):
    """The folder of ui/ that a quoted import in the QML file `path` resolves into, or None."""
    if imported.startswith('/') or ':' in imported:
        return None

    target = posixpath.normpath(posixpath.join(posixpath.dirname(path), imported))
    # A path with an extension names a file (a script or a QML document); any other a directory.
    if '.' in posixpath.basename(target):
        target = posixpath.dirname(target)
    if not target.startswith(UI):
        return None

    return target[len(UI):]


def registered_types(sources):
    """Return {name: folder} of the C++ types that headers or module interfaces of ui/ register for QML.

    `QML_NAMED_ELEMENT(Name)` / `[[qt_qml_named("Name")]]` registers Name; `QML_ELEMENT` /
    `[[qt::qml_element]]` registers the class it sits on."""
    owners = {}
    for path, text in sources.items():
        if not path.endswith(('.hpp', '.h', '.cppm')):
            continue

        for registration in QML_REGISTRATION_RE.finditer(text):
            name = registration.group(1)
            if name is None:
                classes = CLASS_RE.findall(text, 0, registration.start())
                if not classes:
                    continue
                name = classes[-1]
            owners[name] = folder(path)

        for name in QT_ATTR_NAMED_RE.findall(text):
            owners[name] = folder(path)

        for name in QT_ATTR_ELEMENT_RE.findall(text):
            owners[name] = folder(path)

    return owners


def qml_graph(sources):
    """Return {folder: folders whose QML or C++ types it names, or whose files it imports}."""
    qml = {path: text for path, text in sources.items() if path.endswith('.qml')}
    # A type name that appears in two folders resolves to the last one in git order.
    owners = {path.rsplit('/', 1)[1][:-len('.qml')]: folder(path) for path in qml}
    patterns = {name: re.compile(r'\b' + re.escape(name) + r'\s*\{') for name in owners}
    # A C++ type is named by any use of its identifier in code, not after a dot: a type, an
    # enum or attached-property scope, or an instantiation.
    registered = registered_types(sources)
    names = re.compile(r'(?<![.\w])(' + '|'.join(map(re.escape, sorted(registered, key=len, reverse=True)))
                       + r')\b') if registered else None
    graph = collections.defaultdict(set)
    for path, text in qml.items():
        node = folder(path)
        for name, owner in owners.items():
            if owner != node and patterns[name].search(text):
                graph[node].add(owner)

        if names is not None:
            for name in set(names.findall(QML_NON_CODE_RE.sub(' ', text))):
                if registered[name] != node:
                    graph[node].add(registered[name])

        for imported in QML_IMPORT_RE.findall(text):
            target = imported_folder(path, imported)
            if target is not None and target != node:
                graph[node].add(target)

    return graph


def include_graph(edges, drop_root, shared_out):
    """Return the C++ graph, with the shared app/ headers as kit when `shared_out`, and
    without the other edges to app/ when `drop_root`."""
    graph = collections.defaultdict(set)
    for _, node, included, header in edges:
        shared = included == 'app' and header in SHARED_HEADERS
        if shared and shared_out:
            included = 'kit'
        if included == 'app' and drop_root and not shared:
            continue

        graph[node].add(included)

    return graph


def strongly_connected(graph):
    """Return the strongly connected components of more than one node, with Tarjan's algorithm."""
    nodes = sorted(set(graph) | {target for targets in graph.values() for target in targets})
    index = {}
    low = {}
    stack = []
    on_stack = set()
    components = []

    def visit(node):
        index[node] = low[node] = len(index)
        stack.append(node)
        on_stack.add(node)
        for target in sorted(graph.get(node, ())):
            if target not in index:
                visit(target)
                low[node] = min(low[node], low[target])
            elif target in on_stack:
                low[node] = min(low[node], index[target])

        if low[node] == index[node]:
            component = []
            while True:
                member = stack.pop()
                on_stack.discard(member)
                component.append(member)
                if member == node:
                    break

            components.append(sorted(component))

    for node in nodes:
        if node not in index:
            visit(node)

    return [component for component in components if len(component) > 1]


def allowed(node, target):
    """Whether the target rules of the UI let `node` depend on `target`."""
    user = node.split('/')[0]
    used = target.split('/')[0]
    if user == 'kit':
        return used == 'kit'
    if user == 'design':
        return used in ('kit', 'design')
    if used in ('kit', 'design'):
        return True

    # A directory of app/ is reachable only from its ancestors.
    return user == 'app' and target.startswith(node + '/')


def summary(label, graph):
    edges = sum(map(len, graph.values()))
    cycles = [(len(cycle), cycle if len(cycle) <= CYCLE_LISTING_LIMIT else '...') for cycle in strongly_connected(graph)]
    return f'{label} edges {edges} cycles: {cycles}'


def report(rev, sources, verbose, rules):
    """Return the report lines and the exit code."""
    edges = include_edges(sources)
    qml = qml_graph(sources)

    root_users = set()
    root_folders = set()
    shared_uses = collections.Counter()
    for path, node, included, header in edges:
        if included != 'app':
            continue
        if header in ROOT_HEADERS:
            root_users.add(path)
            root_folders.add(node)
        if header in SHARED_HEADERS:
            shared_uses[header] += 1

    as_is = include_graph(edges, drop_root=False, shared_out=False)
    without_root = include_graph(edges, drop_root=True, shared_out=True)
    lines = [
        f'== {rev}',
        f'root header includers outside app: {len(root_users)} files in {len(root_folders)} folders: '
        f'{sorted(root_folders)}',
        f'shared app headers used from outside: {dict(shared_uses)}',
        summary('C++ as is', as_is),
        summary('C++ shared->kit', include_graph(edges, drop_root=False, shared_out=True)),
        summary('C++ shared out + no root edges', without_root),
        summary('QML', qml),
    ]
    if verbose:
        lines += [f'   {node} -> {sorted(without_root[node])}' for node in sorted(without_root)]
        lines.append('root users:')
        lines += [f'   {path}' for path in sorted(root_users)]
        lines.append('QML edges:')
        lines += [f'   {node} -> {sorted(qml[node])}' for node in sorted(qml) if qml[node]]

    if not rules:
        return lines, 0

    folders = {folder(path) for path in sources}
    violations = sorted(f'{node} is outside {", ".join(TREES)}' for node in folders
                        if node.split('/')[0] not in TREES)
    violations += sorted({f'C++ {node} -> {target}' for _, node, target, _ in edges if not allowed(node, target)}
                         | {f'QML {node} -> {target}' for node, targets in qml.items() for target in targets
                            if not allowed(node, target)})
    violations += [f'{kind} cycle {cycle}' for kind, graph in (('C++', as_is), ('QML', qml))
                   for cycle in strongly_connected(graph)]
    lines.append(f'rule violations: {len(violations)}')
    lines += [f'   {violation}' for violation in violations]
    return lines, 1 if violations else 0


if __name__ == '__main__':
    main()
