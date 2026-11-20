#!/usr/bin/env python3
"""Move a domain of a process to another folder of that process and rename what follows from
its path: its modules, its CMake target, alias and DEPS entries, its CTest label and every
path that names it.

    tools/move-cpp-domain.py runtime http=traffic/http tls=traffic/tls

A module is named by its path (rule 1 of tools/check-cpp-modules.py), so moving
src/runtime/http to src/runtime/traffic/http renames telar.runtime.http.message to
telar.runtime.traffic.http.message in every importer, runtime-http to runtime-traffic-http and
the label runtime.http to runtime.traffic.http. Namespaces stay as they are. Run
tools/check-cpp-modules.py afterwards: it names what the move could not decide, such as the
EXCLUDE of a domain that now holds others.

    tools/move-cpp-domain.py --seal src/runtime/traffic

gives the folder one entry of public_modules in place of those of the domains below it.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
# Text the move may rewrite. Vendored trees, the site and the task log name no domain of ours.
SUFFIXES = ('.cpp', '.cppm', '.hpp', '.h', '.mm', '.m', '.c', '.py', '.cmake', '.txt', '.json', '.md',
            '.yml', '.yaml', '.sh', '.lua', '.in', '.toml')
NAMES = ('justfile', '.clangd', '.tbc.json')
# tools/tests holds the checker's own fixtures: made-up trees, not references to this one.
SKIPPED = ('vendor/', 'site/', 'tools/diagram-renderer/', 'tools/tests/', 'docs/audits/', 'TODO.md',
           'tools/move-cpp-domain.py')
# A line that selects tests by label.
LABEL_LINE_RE = re.compile(r'ctest|tools/cpp test|just [\w-]*test|-LE? |LABELS?\b')
CODE = ('.cpp', '.cppm', '.hpp', '.h', '.mm', '.m', '.c')
CMAKE = ('.cmake', 'CMakeLists.txt')


def tracked():
    files = subprocess.check_output(['git', 'ls-files'], cwd=ROOT, text=True).splitlines()
    return [name for name in files
            if (name.endswith(SUFFIXES) or name.rsplit('/', 1)[-1] in NAMES) and not name.startswith(SKIPPED)]


def rules(process, old, new):
    """The rewrites of one move as (pattern, replacement, applies(path), line): a rewrite with a
    `line` pattern touches only the lines that match it."""
    dots = lambda folder: folder.replace('/', '.')
    everywhere = lambda path: True
    cmake = lambda path: path.endswith(CMAKE)
    prose = lambda path: not path.endswith(CODE)
    own_code = lambda path: path.startswith(f'src/{process}/') and path.endswith(CODE)
    return [
        # Paths, from the repository root and from the process's include root.
        (re.compile(rf'src/{process}/{re.escape(old)}(?![\w-])'), f'src/{process}/{new}', everywhere, None),
        # Only a header the moved folder holds: another include root may spell the same folder.
        (re.compile(rf'(#[ \t]*include[ \t]*"){re.escape(old)}/([^"\n]+)(?=")'),
         lambda match: (f'{match[1]}{new}/{match[2]}' if (ROOT / f'src/{process}/{new}/{match[2]}').exists() else match[0]),
         own_code, None),
        # Module names.
        (re.compile(rf'(?<![\w.])telar\.{process}\.{re.escape(dots(old))}(?!\w)'), f'telar.{process}.{dots(new)}',
         everywhere, None),
        # CMake aliases. A namespace spells the same and stays, so only CMake files.
        (re.compile(rf'telar::{process}::{old.replace("/", "::")}(?![\w:])'), f'telar::{process}::{new.replace("/", "::")}',
         cmake, None),
        # Targets: runtime-http, runtime-http-tests, runtime-http-tests-support.
        (re.compile(rf'(?<![\w-]){process}-{old.replace("/", "-")}(?!\w)(?!-(?!tests))'), f'{process}-{new.replace("/", "-")}',
         prose, None),
        # CTest labels, plain and escaped for a regular expression, where a line selects tests: a
        # configuration key spells the same (runtime.proxy.enabled) and stays.
        (re.compile(rf'(?<![\w.]){process}(\\?)\.{re.escape(dots(old))}(?![\w])'),
         lambda match: f'{process}{match[1]}.' + dots(new).replace('.', match[1] + '.'), prose, LABEL_LINE_RE),
    ]


DOMAIN_CALL_RE = re.compile(r'\b(telar_add_domain|telar_add_domain_tests)\(([^()]*)\)')
FOREACH_RE = re.compile(r'foreach\(domain IN ITEMS([^()]*)\)')


def rewrite_cmake(path, text, process, moves):
    """The domain names CMake spells bare: telar_add_domain(<process> <domain> ... DEPS <domain>...),
    telar_add_domain_tests(<domain>) and the list of domains a process adds."""
    if not path.startswith(f'src/{process}/'):
        return text

    def tokens(body, first):
        """Rename the domain tokens of a call's arguments; `first` is the index of its domain."""
        parts = re.split(r'(\s+)', body)
        words = [index for index, part in enumerate(parts) if part and not part.isspace()]
        in_deps = False
        for position, index in enumerate(words):
            word = parts[index]
            if position == first or in_deps:
                parts[index] = moves.get(word, word)
            if word.isupper():
                in_deps = word == 'DEPS'
        return ''.join(parts)

    def call(match):
        if match[1] == 'telar_add_domain':
            if match[2].split()[:1] != [process]:
                return match[0]
            return f'{match[1]}({tokens(match[2], 1)})'
        return f'{match[1]}({tokens(match[2], 0)})'

    text = DOMAIN_CALL_RE.sub(call, text)
    if path == f'src/{process}/CMakeLists.txt':
        text = FOREACH_RE.sub(lambda match: 'foreach(domain IN ITEMS' + re.sub(
            r'[\w/]+', lambda word: moves.get(word[0], word[0]), match[1]) + ')', text)
    return text


def rewrite_layers(text, process, moves):
    """The domains of process_layers in docs/build/modules.json."""
    start = text.index('"process_layers"')
    start = text.index(f'"{process}": [', start) + len(f'"{process}": [')
    end = text.index(']', start)
    block = re.sub(r'"([\w/]+)"', lambda match: '"' + moves.get(match[1], match[1]) + '"', text[start:end])
    return text[:start] + block + text[end:]


def seal(folder):
    """Give `folder` one entry of public_modules in place of those of the domains below it: the
    modules a unit outside the folder imports today. The domains inside then import each other
    without making anything public."""
    spec = importlib.util.spec_from_file_location('check_cpp_modules', ROOT / 'tools/check-cpp-modules.py')
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)

    path = ROOT / 'docs/build/modules.json'
    text = path.read_text()
    inventory = json.loads(text)
    public = {name: modules for name, modules in inventory['public_modules'].items()
              if name != folder and not name.startswith(folder + '/')}
    public[folder] = []
    files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard'],
                                    cwd=ROOT, text=True).splitlines()
    sources = {name: (ROOT / name).read_text(errors='replace') for name in files
               if name.startswith(checker.SCOPES) and name.endswith(checker.IMPORTING_SUFFIXES) and (ROOT / name).is_file()}
    try:
        checker.check_public_modules(public, inventory['interfaces'], sources)
    except RuntimeError as error:
        for line in str(error).splitlines()[1:]:
            match = re.fullmatch(rf'  \S+ imports (\S+), which {re.escape(folder)} does not make public', line)
            # A module that moved into the folder leaves the list of the folder it came from.
            stale = re.fullmatch(r'  (\S+) is public in (\S+), but nothing outside imports it; remove it from public_modules', line)
            if match:
                public[folder].append(match[1])
            elif stale:
                public[stale[2]].remove(stale[1])
            else:
                raise SystemExit('Fix this before sealing: ' + line.strip())
    public[folder].sort()

    start = text.index('  "public_modules": {')
    end = text.index('\n  }', start) + len('\n  }')
    block = json.dumps({'public_modules': dict(sorted(public.items()))}, indent=2)[2:-2]
    path.write_text(text[:start] + block + text[end:])
    print(f'{folder} makes {len(public[folder])} modules public')


def load_checker():
    spec = importlib.util.spec_from_file_location('check_cpp_modules', ROOT / 'tools/check-cpp-modules.py')
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    return checker


MISSING_DEP_RE = re.compile(r'  (\S+): telar_add_domain\((\w+) (\S+)\) does not depend on (\S+), but ')
UNUSED_DEP_RE = re.compile(r'  (\S+): telar_add_domain\((\w+) (\S+)\) depends on (\S+), which none of its files imports')


def fix_deps():
    """Make the DEPS of each telar_add_domain the domains its files import (rule 7): add those the
    checker misses and drop those it finds unused, lowest layer first."""
    checker = load_checker()
    inventory = json.loads((ROOT / 'docs/build/modules.json').read_text())
    files = set(subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard'],
                                        cwd=ROOT, text=True).splitlines())
    files = {name for name in files if (ROOT / name).is_file()}
    try:
        checker.check_domain_targets(inventory['process_layers'], files, lambda path: (ROOT / path).read_text())
        return
    except RuntimeError as error:
        lines = str(error).splitlines()[1:]

    changes = {}
    for line in lines:
        missing, unused = MISSING_DEP_RE.match(line), UNUSED_DEP_RE.match(line)
        found = missing or unused
        if not found:
            raise SystemExit('Fix this by hand: ' + line.strip())
        added, removed = changes.setdefault((found[1], found[2], found[3]), (set(), set()))
        (added if missing else removed).add(found[4])

    for (path, process, domain), (added, removed) in changes.items():
        order = inventory['process_layers'][process]
        text = (ROOT / path).read_text()
        call = re.search(rf'telar_add_domain\({process} {re.escape(domain)}\b([^()]*)\)', text)
        body = call[1]
        deps = re.search(r'\n(\s*)DEPS((?:[ \t]+\S+)*)', body)
        current = deps[2].split() if deps else []
        domains = [name for name in current if name in order]
        others = [name for name in current if name not in order]
        domains = sorted((set(domains) | added) - removed, key=order.index)
        line = ' '.join(domains + others)
        if deps:
            new_body = body[:deps.start()] + (f'\n{deps[1]}DEPS {line}' if line else '') + body[deps.end():]
        else:
            new_body = body.rstrip() + f'\n  DEPS {line}'
        (ROOT / path).write_text(text[:call.start(1)] + new_body + text[call.end(1):])
    print(f'fixed the DEPS of {len(changes)} domains')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--seal', metavar='FOLDER', help='merge the public_modules entries below FOLDER into its own')
    parser.add_argument('--fix-deps', action='store_true', help='make every domain depend on exactly what it imports')
    parser.add_argument('--rewrite-only', action='store_true',
                        help='the folders already moved: only rename what follows from their paths')
    parser.add_argument('process', nargs='?', choices=('runtime', 'cli', 'gui'))
    parser.add_argument('moves', nargs='*', metavar='OLD=NEW', help='folders below src/<process>')
    arguments = parser.parse_args()
    if arguments.seal:
        seal(arguments.seal.rstrip('/'))
        return
    if arguments.fix_deps:
        fix_deps()
        return
    if not arguments.process or not arguments.moves:
        parser.error('name a process and its moves, or --seal a folder')
    moves = dict(move.split('=') for move in arguments.moves)

    for old, new in moves.items():
        source, target = ROOT / f'src/{arguments.process}/{old}', ROOT / f'src/{arguments.process}/{new}'
        if not arguments.rewrite_only and (not source.is_dir() or target.exists()):
            raise SystemExit(f'{old}={new}: the source must be a folder and the target must not exist')
    # A folder that moves into one that stays is renamed first, so the longer names go first.
    ordered = sorted(moves.items(), key=lambda move: len(move[0]), reverse=True)
    for old, new in ordered:
        if arguments.rewrite_only:
            break
        target = ROOT / f'src/{arguments.process}/{new}'
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git', 'mv', f'src/{arguments.process}/{old}', f'src/{arguments.process}/{new}'], cwd=ROOT, check=True)

    changed = 0
    for name in tracked():
        path = ROOT / name
        try:
            text = path.read_text()
        except (UnicodeDecodeError, FileNotFoundError):
            continue
        result = text
        # One pass per move with a placeholder, so that a new name never matches an old one.
        marks = {}
        for index, (old, new) in enumerate(ordered):
            for pattern, replacement, applies, line in rules(arguments.process, old, new):
                if not applies(name):
                    continue

                def mark(match, replacement=replacement):
                    value = replacement(match) if callable(replacement) else match.expand(replacement)
                    key = f'\x00{len(marks)}\x00'
                    marks[key] = value
                    return key

                if line is None:
                    result = pattern.sub(mark, result)
                else:
                    result = '\n'.join(pattern.sub(mark, text_line) if line.search(text_line) else text_line
                                       for text_line in result.split('\n'))
        for key, value in marks.items():
            result = result.replace(key, value)
        if name.endswith(CMAKE):
            result = rewrite_cmake(name, result, arguments.process, moves)
        if name == 'docs/build/modules.json':
            result = rewrite_layers(result, arguments.process, moves)
        if result != text:
            path.write_text(result)
            changed += 1
    print(f'moved {len(moves)} domains of {arguments.process}; rewrote {changed} files')


if __name__ == '__main__':
    main()
