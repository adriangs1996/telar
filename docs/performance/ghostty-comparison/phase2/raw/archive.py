#!/usr/bin/env python3
"""Archive curated phase-two evidence after all measurements have stopped."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile

EXTENSIONS = {'.json', '.log', '.txt', '.py', '.m', '.lua', '.patch'}
BLOCKED_DIRECTORIES = {'cache', '.cache', '.zig-cache', 'zig-out', '__pycache__',
                       'node_modules', 'data', 'certs', 'certificates', 'keys', 'proc'}
BLOCK_BYTES = 1024 * 1024

DIRECTORIES = [
    ('/tmp/tgb-p2-repeat', 'exploratory-v1/repeat'),
    ('/tmp/tgb-p2-variable', 'exploratory-v1/variable'),
    ('/tmp/tgb-p2-followup', 'exploratory-v1/followup'),
    ('/tmp/tgb-p2-stable-repeat', 'final/repeat'),
    ('/tmp/tgb-p2-stable-variable', 'final/variable'),
    ('/tmp/tgb-p2-stable-followup', 'final/followup'),
    ('/tmp/tgb-p2-final-frame-baseline-shared-clock', 'final-frame/baseline-phase1'),
    ('/tmp/tgb-p2-final-frame-candidate-shared-clock', 'final-frame/candidate-v1'),
    ('/tmp/tgb-p2-stable-final-frame', 'final-frame/candidate-stable'),
    ('/tmp/tgb-p2-final-frame', 'invalid-clock/candidate-original'),
    ('/tmp/tgb-p2-final-frame-baseline', 'invalid-clock/baseline-original'),
    ('/tmp/tgb-phase2-validation', 'validation'),
]
FILES = [
    ('/tmp/tgb-phase2-final-frame-process-clock.py', 'invalid-clock/runner-process-clock.py'),
    ('/tmp/tgb-phase2-final-frame.py', 'final-frame/runner.py'),
    ('/tmp/tgb-phase2-followup.py', 'scripts/followup-v1.py'),
    ('/tmp/tgb-phase2-stable-followup.py', 'scripts/followup-stable.py'),
    ('/tmp/tgb-phase2-native-ab.py', 'scripts/native-v1.py'),
    ('/tmp/tgb-phase2-final-native.py', 'scripts/native-final.py'),
    ('/tmp/tgb-phase2-variable-continue.py', 'scripts/variable-continuation.py'),
    ('/tmp/tgb-phase2-profile-summary.py', 'scripts/profile-summary.py'),
]


def nofollow_open(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise ValueError(f'not a regular file: {path}')
    return os.fdopen(descriptor, 'rb')


def digest_file(path):
    digest = hashlib.sha256()
    with nofollow_open(path) as source:
        for chunk in iter(lambda: source.read(BLOCK_BYTES), b''):
            digest.update(chunk)
    return digest.hexdigest()


def safe_parent(root, relative):
    if relative.is_absolute() or '..' in relative.parts:
        raise ValueError(f'unsafe archive path: {relative}')
    current = root
    for component in relative.parent.parts:
        current = current / component
        if current.is_symlink():
            raise ValueError(f'destination symlink: {current}')
        current.mkdir(exist_ok=True)
        if not current.is_dir():
            raise ValueError(f'destination parent is not a directory: {current}')
    return root / relative


def copy_exact(source, root, relative):
    destination = safe_parent(root, relative)
    if destination.is_symlink():
        raise ValueError(f'destination symlink: {destination}')
    with nofollow_open(source) as incoming:
        before = os.fstat(incoming.fileno())
        descriptor, name = tempfile.mkstemp(prefix='.archive-', dir=destination.parent)
        temporary = Path(name)
        digest = hashlib.sha256()
        try:
            with os.fdopen(descriptor, 'wb') as outgoing:
                for chunk in iter(lambda: incoming.read(BLOCK_BYTES), b''):
                    outgoing.write(chunk)
                    digest.update(chunk)
            after = os.fstat(incoming.fileno())
            if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise RuntimeError(f'source changed during archiving: {source}')
            checksum = digest.hexdigest()
            if destination.exists():
                if destination.stat().st_size != after.st_size or digest_file(destination) != checksum:
                    raise RuntimeError(f'refusing to overwrite different archived bytes: {destination}')
                created = False
            else:
                # Link exclusively: even a concurrent archiver cannot overwrite a file.
                os.link(temporary, destination)
                created = True
            return dict(source=str(source), destination=str(relative),
                        bytes=after.st_size, sha256=checksum), created
        finally:
            temporary.unlink(missing_ok=True)


def excluded(path):
    name = path.name.lower()
    if name == 'test-symbols.log':
        return 'irrelevant symbol dump'
    if any(token in name for token in ('private-key', 'private_key', 'certificate', '.pem', '.p12', '.pfx')):
        return 'certificate or key artifact'
    if path.suffix.lower() not in EXTENSIONS and name != 'host-output.bin':
        return 'extension outside evidence whitelist'
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path(
        '/Users/adriangonzalez/sandbox/telar/docs/performance/ghostty-comparison/phase2/raw'))
    args = parser.parse_args()
    output = args.output.absolute()
    # Reject user-provided destination symlinks, including ancestor directories.
    for component in (output, *output.parents):
        if component.is_symlink():
            raise ValueError(f'destination contains a symlink: {component}')
    output.mkdir(parents=True, exist_ok=True)
    output = output.resolve()
    copied, omitted, errors = [], [], []
    created_count = 0

    def omit(source, reason):
        omitted.append(dict(source=str(source), reason=reason))

    def copy(source, relative):
        nonlocal created_count
        reason = excluded(source)
        if reason:
            omit(source, reason)
            return
        if source.is_symlink():
            omit(source, 'symlink; never followed')
            return
        try:
            record, created = copy_exact(source, output, relative)
            copied.append(record)
            created_count += int(created)
        except Exception as error:
            errors.append(dict(source=str(source), destination=str(relative),
                               error=f'{type(error).__name__}: {error}'))

    for source_name, target_name in DIRECTORIES:
        source = Path(source_name)
        if source.is_symlink():
            omit(source, 'source-root symlink; never followed')
            errors.append(dict(source=str(source), error='source root is a symlink'))
            continue
        if not source.is_dir():
            omit(source, 'missing expected source directory')
            errors.append(dict(source=str(source), error='missing expected source directory'))
            continue
        # Canonicalize the platform /tmp alias once; do not follow entries inside it.
        source = source.resolve()
        for current, directories, names in os.walk(source, followlinks=False):
            directory = Path(current)
            for name in sorted(directories):
                child = directory / name
                if child.is_symlink():
                    omit(child, 'symlink directory; never followed')
                    directories.remove(name)
                elif name in BLOCKED_DIRECTORIES or name.endswith('.app'):
                    omit(child, 'non-evidence directory; contents not enumerated')
                    directories.remove(name)
            directories.sort()
            for name in sorted(names):
                child = directory / name
                if not stat.S_ISREG(child.lstat().st_mode) and not child.is_symlink():
                    omit(child, 'socket, device, FIFO or other non-regular entry')
                    continue
                copy(child, Path(target_name) / child.relative_to(source))

    for source_name, target_name in FILES + [(str(Path(__file__).absolute()), 'archive.py')]:
        source = Path(source_name)
        if not source.exists() and not source.is_symlink():
            omit(source, 'missing expected standalone script')
            errors.append(dict(source=str(source), error='missing expected standalone script'))
            continue
        # Unlike directory roots, never resolve a final source-file symlink.
        copy(source, Path(target_name))

    manifest = dict(format_version=1, complete=not errors,
                    allowed_extensions=sorted(EXTENSIONS), allowed_binary_name='host-output.bin',
                    sources=[dict(source=source, destination=target) for source, target in DIRECTORIES],
                    classifications={
                        'exploratory-v1': 'Earlier candidate; never pool with final stable binaries.',
                        'exploratory-v1/variable': 'Incomplete superseded series; retains failures, continuation and rate misses.',
                        'final': 'Final stable series; completeness is determined by its original run artifacts.',
                        'invalid-clock': 'Invalid cross-process timing; original bytes and annotations retained.',
                        'validation': 'Raw logs include known failures; copying does not assert tests passed.'},
                    files=sorted(copied, key=lambda item: item['destination']),
                    copied_file_count=len(copied), copied_bytes=sum(item['bytes'] for item in copied),
                    omissions=sorted(omitted, key=lambda item: (item['source'], item['reason'])),
                    omission_count=len(omitted), omission_reasons=dict(Counter(item['reason'] for item in omitted)),
                    omission_count_unit='Observed entries; skipped directories count once and their contents are not inspected.',
                    errors=errors)
    manifest_path = output / 'archive-manifest.json'
    if manifest_path.is_symlink():
        raise ValueError('archive manifest is a symlink')
    content = json.dumps(manifest, indent=2, sort_keys=True) + '\n'
    if not manifest_path.exists() or manifest_path.read_text() != content:
        descriptor, name = tempfile.mkstemp(prefix='.archive-manifest-', dir=output)
        try:
            with os.fdopen(descriptor, 'w') as temporary:
                temporary.write(content)
            os.replace(name, manifest_path)
        finally:
            Path(name).unlink(missing_ok=True)
    print(json.dumps(dict(manifest=str(manifest_path), complete=not errors,
                          files=len(copied), newly_copied=created_count,
                          unchanged_files=len(copied) - created_count,
                          omitted_entries=len(omitted), errors=len(errors))))
    return 0 if not errors else 1


if __name__ == '__main__':
    raise SystemExit(main())
