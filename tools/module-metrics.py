#!/usr/bin/env python3
"""Measure how the C++ module graph makes changes rebuild the tree.

The graph metrics come from the module units git tracks, outside tests and
vendored code, and depend only on the commit:

- interface share: physical lines in interface units (`export module`) against
  implementation units (`module X;`) and internal partitions.
- transitive dependents: modules that rebuild when a module's interface changes.
  An import from an implementation unit counts as a dependency of its module.
- upward edges: components are `lib/<library>` and `<process>/<top folder>`.
  They are ordered bottom-up with Eades-Lin-Smyth over the component graph,
  weighted by module edges and breaking ties by name. An import of a component
  placed above the importer is an upward edge.
- cycles: elementary cycles of the module graph, implementation imports included.
- export import edges: module pairs where an interface re-exports the import.
- critical path: the longest chain of interface imports, which bounds the build.

`--build DIR` adds what depends on the machine. It configures DIR from nothing
with the dev preset and builds the three processes in it, as `just
runtime-build` and `just gui-build` do in a fresh worktree, and samples the
memory of the whole process tree for the peak. On the finished tree it counts
the lines each module unit carries in its global fragment, preprocessed with
its real flags, and the units `ninja -n` rebuilds for each process after
touching the interface of each hub. Each machine keeps its own entry in
the output, so running the script on another machine adds to the baseline.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
SCOPES = ('lib/', 'src/')
SOURCE_RE = re.compile(r'\.(cppm|cpp|cc|cxx|mm)$')
DECLARATION_RE = re.compile(r'^[ \t]*(export[ \t]+)?module[ \t]+([A-Za-z_][\w.]*)(:[\w.]+)?[ \t]*;', re.M)
IMPORT_RE = re.compile(r'^[ \t]*(export[ \t]+)?import[ \t]+([A-Za-z_][\w.]*|:[\w.]+)(:[\w.]+)?[ \t]*;', re.M)
STANDARD_MODULES = {'std', 'std.compat'}
HUB_TABLE = 25
CYCLE_LIMIT = 10000
# The targets `just runtime-build` and `just gui-build` build: the three processes.
PROCESSES = {
    'runtime': ('telar-runtime', 'telar'),
    'gui': ('telar-gui', 'telar-gui-command'),
}
COMPILE_RE = re.compile(r'\] Building (?:C|CXX|OBJC|OBJCXX) object ')
OBJECT_RE = re.compile(r'\s-o\s+\S+\.o(?:\s|$)')
# Clang writes the module directives of preprocessed output with a reserved spelling.
PREPROCESSED_RE = re.compile(r'^(?:export\s+)?(?:__preprocessed_)?module\s*([\w.:]*)\s*;')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/build/module-metrics.json')
    parser.add_argument('--build', type=Path, help='empty directory for the tree of the cold build of the three processes')
    parser.add_argument('--reuse', action='store_true', help='measure a finished --build directory without building')
    parser.add_argument('--machine', default=platform.node().split('.')[0], help='label of this machine in the output')
    parser.add_argument('--hubs', type=int, default=8, help='modules with most dependents to touch with ninja -n')
    args = parser.parse_args()

    units = scan_units()
    graph = module_graph(units)
    metrics = graph_metrics(units, graph)

    baseline = json.loads(args.output.read_text()) if args.output.exists() else {}
    baseline['commit'] = commit()
    baseline['graph'] = metrics
    machines = baseline.setdefault('machines', {})

    if args.build:
        # A reused tree keeps the cold build measured when it was built.
        measured = build_metrics(args.build.resolve(), args.reuse, units, graph, metrics, args.hubs)
        machines[args.machine] = {**machines.get(args.machine, {}), **measured}

    args.output.write_text(json.dumps(baseline, indent=2, ensure_ascii=False) + '\n')
    summary(baseline)


def commit():
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', 'lib', 'src'], cwd=ROOT).returncode != 0

    return head + ('+dirty' if dirty else '')


def production(path):
    return path.startswith(SCOPES) and not {'tests', 'vendor'} & set(path.split('/'))


def scan_units():
    """Every production module unit: its file, kind, module and imports."""
    files = subprocess.check_output(['git', 'ls-files'], cwd=ROOT, text=True).splitlines()
    units = []
    for path in sorted(files):
        if not SOURCE_RE.search(path) or not production(path) or not (ROOT / path).is_file():
            continue

        text = (ROOT / path).read_text(errors='replace')
        declaration = DECLARATION_RE.search(text)
        if not declaration:
            continue

        primary, partition = declaration[2], declaration[3] or ''
        kind = 'interface' if declaration[1] else 'partition' if partition else 'implementation'
        imports = {}
        for exported, name, suffix in IMPORT_RE.findall(text):
            target = primary + name if name.startswith(':') else name + suffix
            if target not in STANDARD_MODULES:
                imports[target] = imports.get(target, False) or bool(exported)

        units.append({
            'path': path,
            'kind': kind,
            'module': primary + partition,
            'lines': text.count('\n'),
            'imports': imports,
        })

    return units


def component(path):
    parts = path.split('/')
    if parts[0] == 'lib':
        return 'lib/' + parts[1]

    process = parts[1].removesuffix('-cpp')
    return process + '/' + (parts[2] if len(parts) > 3 else '(root)')


def module_graph(units):
    """Module edges with their flags, and the component of each module."""
    modules = {unit['module']: unit for unit in units if unit['kind'] != 'implementation'}
    edges = {}
    for unit in units:
        source = unit['module']
        for target, exported in unit['imports'].items():
            if target not in modules or target == source:
                continue

            edge = edges.setdefault((source, target), {'export': False, 'implementation_only': True})
            edge['export'] |= exported
            edge['implementation_only'] &= unit['kind'] == 'implementation'

    return {
        'modules': sorted(modules),
        'component': {name: component(unit['path']) for name, unit in modules.items()},
        'interface': {name: unit['path'] for name, unit in modules.items()},
        'edges': edges,
    }


def graph_metrics(units, graph):
    interface_lines = sum(unit['lines'] for unit in units if unit['kind'] == 'interface')
    implementation_lines = sum(unit['lines'] for unit in units if unit['kind'] != 'interface')
    edges = graph['edges']
    dependents = transitive_dependents(graph)
    hubs = sorted(graph['modules'], key=lambda name: (-dependents[name], name))[:HUB_TABLE]
    order, upward = layering(graph)
    cycles = elementary_cycles(graph)
    path = critical_path(graph)

    return {
        'modules': len(graph['modules']),
        'components': len(order),
        'interface_lines': interface_lines,
        'implementation_lines': implementation_lines,
        'interface_share': round(interface_lines / (interface_lines + implementation_lines), 4),
        'edges': len(edges),
        'export_import_edges': sum(edge['export'] for edge in edges.values()),
        'implementation_only_edges': sum(edge['implementation_only'] for edge in edges.values()),
        'transitive_dependents': {name: dependents[name] for name in hubs},
        'upward_component_edges': len({(graph['component'][a], graph['component'][b]) for a, b in upward}),
        'upward_module_edges': len(upward),
        'upward': [f'{a} -> {b}' for a, b in upward],
        'cycles': len(cycles),
        'cycle_list': [' -> '.join(cycle + cycle[:1]) for cycle in cycles],
        'critical_path_length': len(path),
        'critical_path': path,
        'layers': order,
    }


def transitive_dependents(graph):
    importers = {name: set() for name in graph['modules']}
    for source, target in graph['edges']:
        importers[target].add(source)

    counts = {}
    for name in graph['modules']:
        reached, pending = set(), [name]
        while pending:
            for importer in importers[pending.pop()]:
                if importer not in reached:
                    reached.add(importer)
                    pending.append(importer)

        reached.discard(name)
        counts[name] = len(reached)

    return counts


def layering(graph):
    """Eades-Lin-Smyth order of the components, bottom first, and the edges it breaks."""
    weights = {}
    for source, target in graph['edges']:
        pair = (graph['component'][source], graph['component'][target])
        if pair[0] != pair[1]:
            weights[pair] = weights.get(pair, 0) + 1

    remaining = set(graph['component'].values())
    dependencies = {name: {} for name in remaining}
    importers = {name: {} for name in remaining}
    for (source, target), weight in weights.items():
        dependencies[source][target] = weight
        importers[target][source] = weight

    bottom, top = [], []
    while remaining:
        # Components that import nothing left go below everything left, and
        # components nothing left imports go above it.
        for side, links in ((bottom, dependencies), (top, importers)):
            progress = True
            while progress:
                progress = False
                for name in sorted(remaining):
                    if not links[name].keys() & remaining:
                        side.append(name)
                        remaining.discard(name)
                        progress = True

        if remaining:
            def balance(name):
                return (sum(weight for other, weight in importers[name].items() if other in remaining)
                        - sum(weight for other, weight in dependencies[name].items() if other in remaining))

            chosen = max(sorted(remaining), key=balance)
            bottom.append(chosen)
            remaining.discard(chosen)

    order = bottom + top[::-1]
    position = {name: index for index, name in enumerate(order)}
    upward = sorted((source, target) for source, target in graph['edges']
                    if position[graph['component'][target]] > position[graph['component'][source]])

    return order, upward


def elementary_cycles(graph):
    """Each cycle once, starting at its smallest module, inside each strongly connected component."""
    successors = {name: set() for name in graph['modules']}
    for source, target in graph['edges']:
        successors[source].add(target)

    cycles = []
    for members in strongly_connected(successors):
        if len(members) < 2:
            continue

        for start in sorted(members):
            allowed = {name for name in members if name > start}
            stack = [(start, iter(sorted(successors[start])))]
            path = [start]
            while stack and len(cycles) < CYCLE_LIMIT:
                node, following = stack[-1]
                step = next(following, None)
                if step is None:
                    stack.pop()
                    path.pop()
                elif step == start:
                    cycles.append(path[:])
                elif step in allowed and step not in path:
                    path.append(step)
                    stack.append((step, iter(sorted(successors[step]))))

    return sorted(cycles)


def strongly_connected(successors):
    index, low, stack, active, groups = {}, {}, [], set(), []
    for root in sorted(successors):
        if root in index:
            continue

        work = [(root, iter(sorted(successors[root])))]
        index[root] = low[root] = len(index)
        stack.append(root)
        active.add(root)
        while work:
            node, following = work[-1]
            step = next(following, None)
            if step is None:
                work.pop()
                if work:
                    low[work[-1][0]] = min(low[work[-1][0]], low[node])

                if low[node] == index[node]:
                    group = set()
                    while True:
                        member = stack.pop()
                        active.discard(member)
                        group.add(member)
                        if member == node:
                            break

                    groups.append(group)
            elif step not in index:
                index[step] = low[step] = len(index)
                stack.append(step)
                active.add(step)
                work.append((step, iter(sorted(successors[step]))))
            elif step in active:
                low[node] = min(low[node], index[step])

    return groups


def critical_path(graph):
    """The longest chain of interface imports, from the importer down."""
    successors = {name: [] for name in graph['modules']}
    for (source, target), edge in graph['edges'].items():
        if not edge['implementation_only']:
            successors[source].append(target)

    longest = {}

    def chain(name):
        if name not in longest:
            longest[name] = [name] + max((chain(target) for target in sorted(successors[name])),
                                         key=len, default=[])

        return longest[name]

    sys.setrecursionlimit(max(sys.getrecursionlimit(), 4 * len(successors)))
    return max((chain(name) for name in graph['modules']), key=len, default=[])


def build_metrics(directory, reuse, units, graph, metrics, hub_count):
    toolchain_path()
    if not reuse and directory.exists() and any(directory.iterdir()):
        raise SystemExit(f'{directory} is not empty: a cold build needs a new directory, or pass --reuse')

    result = {
        'commit': commit(),
        'date': datetime.date.today().isoformat(),
        'system': f'{platform.system()} {platform.release()} {platform.machine()}',
        'cpus': os.cpu_count(),
        'memory_mib': physical_memory() >> 20,
    }
    if not reuse:
        result['cold_build'] = cold_build(directory)

    result['compile_units'] = {name: len(compile_commands(directory, targets)) for name, targets in PROCESSES.items()}
    result['global_fragment'] = global_fragments(directory, units)

    hubs = list(metrics['transitive_dependents'])[:hub_count]
    result['ninja_rebuilds'] = {hub: rebuilds(ROOT / graph['interface'][hub], directory) for hub in hubs}

    return result


def toolchain_path():
    subprocess.run([sys.executable, str(ROOT / 'tools/cpp'), 'bootstrap'], check=True)
    os.environ['PATH'] = str(ROOT / '.toolchain/bin') + os.pathsep + os.environ['PATH']


def physical_memory():
    if platform.system() == 'Darwin':
        return int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True))

    return os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES')


def cold_build(directory):
    """Wall time and peak resident memory of configuring the tree and building each process.

    Configure is timed apart: it can wait for another worktree building a shared
    dependency, which says nothing about the cost of compiling telar. The runtime
    builds first, so the GUI's time leaves out the libraries both link.
    """
    directory.mkdir(parents=True, exist_ok=True)
    cpp = [sys.executable, str(ROOT / 'tools/cpp')]
    steps = [('configure', None, [*cpp, 'configure', 'dev', '-B', str(directory)])]
    steps += [('build', name, [*cpp, 'build', 'dev', '-B', str(directory), '--', '--target', *targets])
              for name, targets in PROCESSES.items()]
    result = {}
    for step, name, command in steps:
        started = time.monotonic()
        process = subprocess.Popen(command)
        peak, load = sample_tree(process)
        if process.returncode != 0:
            raise SystemExit(f'{" ".join(command[1:])} failed with {process.returncode}')

        entry = result.setdefault(name or 'tree', {})
        entry[step + '_seconds'] = round(time.monotonic() - started, 1)
        entry[step + '_peak_memory_mib'] = peak >> 10
        entry[step + '_load_average'] = load

    builds = [result[name] for name in PROCESSES]
    result['build_seconds'] = round(sum(entry['build_seconds'] for entry in builds), 1)
    result['peak_memory_mib'] = max([result['tree']['configure_peak_memory_mib']] +
                                    [entry['build_peak_memory_mib'] for entry in builds])
    return result


def sample_tree(process):
    """Wait for the process: peak resident KiB of it and its descendants, and mean load.

    Other builds on the machine slow this one down, so the load says how much
    the time can be trusted.
    """
    peak, loads, done = 0, [], threading.Event()

    def sample():
        nonlocal peak
        while not done.is_set():
            table = subprocess.run(['ps', '-A', '-o', 'pid=,ppid=,rss='], capture_output=True, text=True).stdout
            children, resident = {}, {}
            for line in table.splitlines():
                fields = line.split()
                if len(fields) == 3:
                    pid, parent, kib = map(int, fields)
                    children.setdefault(parent, []).append(pid)
                    resident[pid] = kib

            total, pending = 0, [process.pid]
            while pending:
                pid = pending.pop()
                total += resident.get(pid, 0)
                pending += children.get(pid, [])

            peak = max(peak, total)
            loads.append(os.getloadavg()[0])
            done.wait(0.25)

    sampler = threading.Thread(target=sample)
    sampler.start()
    process.wait()
    done.set()
    sampler.join()
    return peak, round(sum(loads) / max(len(loads), 1), 1)


def compile_commands(tree, targets):
    """The compiler commands the targets of a tree run."""
    commands = subprocess.check_output(['ninja', '-C', str(tree), '-t', 'commands', *targets], text=True)
    return [line for line in commands.splitlines() if OBJECT_RE.search(line)]


def global_fragments(tree, units):
    """Preprocessed lines before the module declaration of each production module unit."""
    paths = {str(ROOT / unit['path']): unit['path'] for unit in units}
    commands = {}
    for entry in json.loads((tree / 'compile_commands.json').read_text()):
        source = str(Path(entry['directory'], entry['file']).resolve())
        if source in paths and paths[source] not in commands:
            commands[paths[source]] = (entry['directory'], preprocess_arguments(entry))

    with ThreadPoolExecutor(os.cpu_count()) as pool:
        lines = dict(zip(commands, pool.map(lambda item: fragment_lines(*item), commands.values())))

    values = sorted(lines.values())
    return {
        'units': len(values),
        'lines': sum(values),
        'median': values[len(values) // 2] if values else 0,
        'largest': dict(sorted(lines.items(), key=lambda item: (-item[1], item[0]))[:HUB_TABLE]),
    }


def preprocess_arguments(entry):
    arguments = entry.get('arguments') or shlex.split(entry['command'])
    kept, skip = [], False
    for argument in arguments:
        if skip:
            skip = False
        elif argument in ('-o', '-MF', '-MT', '-MQ'):
            skip = True
        elif argument in ('-c', '-MD', '-MMD') or argument.startswith(('@', '-fmodule-output', '-fmodule-file')):
            continue
        else:
            kept.append(argument)

    return kept + ['-E']


def fragment_lines(directory, arguments):
    output = subprocess.run(arguments, cwd=directory, capture_output=True, text=True, errors='replace')
    if output.returncode != 0:
        raise RuntimeError(f'Preprocessing failed in {directory}: {output.stderr[:2000]}')

    count = 0
    for line in output.stdout.splitlines():
        directive = PREPROCESSED_RE.match(line)
        if directive and directive[1]:
            return count

        # Line markers and blank lines carry no declarations.
        if line.strip() and not line.startswith('#') and not directive:
            count += 1

    return 0


def rebuilds(interface, tree):
    """Compile units `ninja -n` runs for each process's targets after touching the interface."""
    before = interface.stat()
    result = {}
    try:
        os.utime(interface)
        for name, targets in PROCESSES.items():
            result[name] = dry_run(tree, targets)
        # The processes share the libraries' units, which the tree compiles once.
        result['total'] = dry_run(tree, [target for targets in PROCESSES.values() for target in targets])
    finally:
        os.utime(interface, ns=(before.st_atime_ns, before.st_mtime_ns))

    return result


def dry_run(tree, targets):
    """Compile units `ninja -n` lists for the targets.

    CMake checks its globs on every build, and a dry run takes that check as a
    changed manifest and stops after regenerating it. A manifest that only
    includes the tree's has no rule to regenerate itself.
    """
    with tempfile.NamedTemporaryFile('w', suffix='.ninja') as manifest:
        manifest.write(f'include {tree / "build.ninja"}\n')
        manifest.flush()
        output = subprocess.check_output(['ninja', '-C', str(tree), '-f', manifest.name, '-n', *targets], text=True)

    return sum(1 for line in output.splitlines() if COMPILE_RE.search(line))


def summary(baseline):
    graph = baseline['graph']
    print(f"commit {baseline['commit']}")
    print(f"{graph['modules']} modules in {graph['components']} components, "
          f"{graph['interface_share']:.1%} of module lines in interfaces "
          f"({graph['interface_lines']} against {graph['implementation_lines']})")
    print(f"{graph['edges']} edges, {graph['export_import_edges']} export import, "
          f"{graph['upward_module_edges']} upward between modules and {graph['upward_component_edges']} between components, "
          f"{graph['cycles']} cycles, critical path of {graph['critical_path_length']} modules")
    for name, count in list(graph['transitive_dependents'].items())[:8]:
        print(f'  {count:4} dependents  {name}')

    for label, machine in baseline.get('machines', {}).items():
        build = machine.get('cold_build')
        if build:
            print(f"{label}: cold build {build['build_seconds']} s without configure, peak {build['peak_memory_mib']} MiB")

        fragment = machine['global_fragment']
        print(f"{label}: {fragment['lines']} global fragment lines in {fragment['units']} units, median {fragment['median']}")
        for hub, counts in machine['ninja_rebuilds'].items():
            print(f"  {counts['total']:4} units rebuilt  {hub}")


if __name__ == '__main__':
    main()
