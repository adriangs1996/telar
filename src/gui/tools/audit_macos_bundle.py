#!/usr/bin/env python3
"""Reject external or missing Mach-O dependencies in a staged preview bundle."""

import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('bundle', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
bundle = args.bundle.resolve()
frameworks = bundle / 'Contents/Frameworks'
macos = bundle / 'Contents/MacOS'
records = []
failures = []
for path in sorted(bundle.rglob('*')):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as stream:
        magic = stream.read(4)
    if magic not in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        continue
    result = subprocess.run(['/usr/bin/otool', '-L', str(path)], capture_output=True, text=True, check=True)
    dependencies = []
    install_name = None
    for line in result.stdout.splitlines():
        if not line.startswith('\t'):
            continue
        name = line.strip().split(' (compatibility version', 1)[0]
        if install_name is None and not dependencies and (path.suffix == '.dylib' or '.framework/' in str(path)) and Path(name).name == path.name:
            install_name = name
            continue
        dependencies.append(name)
        if name.startswith(('/System/Library/', '/usr/lib/')):
            continue
        if name.startswith('@loader_path/'):
            candidates = [path.parent / name.removeprefix('@loader_path/')]
        elif name.startswith('@executable_path/'):
            candidates = [macos / name.removeprefix('@executable_path/')]
        elif name.startswith('@rpath/'):
            suffix = name.removeprefix('@rpath/')
            candidates = [frameworks / suffix, path.parent / suffix, macos / suffix]
        else:
            candidates = []
        if not any(candidate.is_file() and candidate.resolve().is_relative_to(bundle) for candidate in candidates):
            failures.append(dict(file=str(path.relative_to(bundle)), dependency=name))
    records.append(dict(file=str(path.relative_to(bundle)), install_name=install_name, dependencies=dependencies))
args.output.write_text(json.dumps(dict(objects=records, failures=failures), indent=2) + '\n')
print(f'Audited {len(records)} Mach-O objects; {len(failures)} unresolved/external dependencies')
raise SystemExit(bool(failures))
