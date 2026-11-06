#!/usr/bin/env python3
"""Check module ownership, import cycles and the documented textual boundaries."""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SCOPES = ('dlls/', 'services/runtime-cpp/', 'services/cli-cpp/',
          'services/gui-cpp/', 'services/auth-daemon/')


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
        graph[name] = {name.split(':')[0] + item if item.startswith(':') else item for item in dependencies}
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
    print(f'{len(graph)} module interfaces, acyclic imports, {len(headers)} justified textual boundaries')


if __name__ == '__main__':
    main()
