#!/usr/bin/env python3
"""Install verified C++ build tools in a repository-local, immutable cache."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'tools/toolchain/manifest.json'


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def prepare(tool, artifact, cache):
    digest = artifact['sha256']
    destination = cache / f'{tool}-{digest[:16]}'
    if (destination / '.complete').is_file():
        return destination
    downloads = cache / 'downloads'
    downloads.mkdir(exist_ok=True)
    archive = downloads / digest
    if not archive.exists():
        temporary = archive.with_suffix('.part')
        print(f'Downloading {artifact["url"]}', flush=True)
        with urllib.request.urlopen(artifact['url']) as response, temporary.open('wb') as output:
            shutil.copyfileobj(response, output)
        if sha256(temporary) != digest:
            temporary.unlink()
            raise RuntimeError(f'{tool}: SHA-256 mismatch')
        temporary.rename(archive)
    if sha256(archive) != digest:
        raise RuntimeError(f'{tool}: corrupt cached archive {archive}')
    with tempfile.TemporaryDirectory(dir=cache) as scratch:
        unpacked = Path(scratch).resolve()
        if artifact['url'].endswith('.zip'):
            with zipfile.ZipFile(archive) as package:
                for info in package.infolist():
                    target = (unpacked / info.filename).resolve()
                    if not target.is_relative_to(unpacked):
                        raise RuntimeError('Unsafe archive path')
                package.extractall(unpacked)
            (unpacked / 'ninja').chmod(0o755)
        else:
            with tarfile.open(archive) as package:
                for member in package.getmembers():
                    target = (unpacked / member.name).resolve()
                    if not target.is_relative_to(unpacked) or not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                        raise RuntimeError('Unsafe archive entry')
                    if member.issym() or member.islnk():
                        base = target.parent if member.issym() else unpacked
                        if not (base / member.linkname).resolve().is_relative_to(unpacked):
                            raise RuntimeError('Unsafe archive link')
                package.extractall(unpacked)
        children = list(unpacked.iterdir())
        content = children[0] if len(children) == 1 and children[0].is_dir() else unpacked
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(content, destination, symlinks=True)
        (destination / '.complete').write_text(digest + '\n')
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=ROOT / '.toolchain')
    parser.add_argument('--from-source', action='store_true', help='Build verified tools with the native SDK (automatic on musl)')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    key = f'{platform.system()}-{platform.machine()}'
    manifest = json.loads(MANIFEST.read_text())
    cache = args.cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    # Concurrent clones may share this cache. Publish only complete installations.
    with (cache / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        source_build = args.from_source or (platform.system() == 'Linux' and bool(list(Path('/lib').glob('ld-musl-*')))) or key not in manifest['artifacts']['llvm']
        if source_build:
            import sys
            sys.path.insert(0, str(ROOT / 'tools/toolchain'))
            from source import build
            prefix = build(manifest, cache, prepare, ROOT, args.jobs)
            paths = {tool: prefix for tool in ('cmake', 'ninja', 'llvm')}
            cmake_bin = prefix / 'bin'
            llvm_bin = cmake_bin
            ninja_bin = cmake_bin
        else:
            paths = {}
            for tool in ('cmake', 'ninja', 'llvm'):
                artifact = manifest['artifacts'][tool].get(key)
                if artifact is None:
                    parser.error(f'No official {tool} binary for {key}; use --from-source')
                paths[tool] = prepare(tool, artifact, cache)
            cmake_bin = paths['cmake'] / ('CMake.app/Contents/bin' if platform.system() == 'Darwin' else 'bin')
            llvm_bin = paths['llvm'] / 'bin'
            ninja_bin = paths['ninja']
        bin_dir = cache / 'bin'
        bin_dir.mkdir(exist_ok=True)
        for directory, names in ((cmake_bin, ('cmake', 'ctest', 'cpack')), (ninja_bin, ('ninja',)),
                                 (llvm_bin, ('clang', 'clang++', 'clang-scan-deps', 'clangd', 'clang-tidy', 'clang-format', 'ld.lld'))):
            for name in names:
                target = directory / name
                if not target.exists():
                    if name == 'ld.lld' and platform.system() == 'Darwin':
                        continue
                    raise RuntimeError(f'Missing tool: {target}')
                link = bin_dir / name
                temporary = bin_dir / (name + '.tmp')
                temporary.unlink(missing_ok=True)
                temporary.symlink_to(target)
                temporary.replace(link)
        toolchain = cache / 'toolchain.cmake'
        toolchain.write_text(
            '# Generated by tools/bootstrap-cpp.py from the checked-in manifest.\n'
            + ''.join(f'set({name} "{value}" CACHE FILEPATH "Pinned tool")\n' for name, value in (
                ('CMAKE_C_COMPILER', llvm_bin / 'clang'),
                ('CMAKE_CXX_COMPILER', llvm_bin / 'clang++'),
                ('CMAKE_OBJC_COMPILER', llvm_bin / 'clang'),
                ('CMAKE_OBJCXX_COMPILER', llvm_bin / 'clang++'),
                ('CMAKE_MAKE_PROGRAM', bin_dir / 'ninja'))))
        if platform.system() == 'Darwin':
            sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
            headers = Path(sdk) / 'usr/include/c++/v1'
            if not (headers / 'version').exists():
                raise RuntimeError('The macOS SDK must provide libc++ headers')
            with toolchain.open('a') as output:
                output.write(f'set(CMAKE_OSX_SYSROOT "{sdk}" CACHE PATH "System SDK")\n')
                for language in ('CXX', 'OBJCXX'):
                    output.write(f'set(CMAKE_{language}_FLAGS_INIT "-nostdinc++ -isystem \\"{headers}\\"")\n')
        if platform.system() == 'Linux':
            with toolchain.open('a') as output:
                output.write('set(CMAKE_CXX_FLAGS_INIT "-stdlib=libc++")\n')
                for kind in ('EXE', 'SHARED', 'MODULE'):
                    output.write(f'set(CMAKE_{kind}_LINKER_FLAGS_INIT "-static-libstdc++")\n')
        if source_build and platform.system() == 'Linux':
            # Every native application dependency is compiled without distro GCC
            # LTO; libc++ and its unwind/compiler runtimes come from this release.
            with toolchain.open('a') as output:
                output.write('set(CMAKE_CXX_FLAGS_INIT "-stdlib=libc++ --rtlib=compiler-rt --unwindlib=libunwind")\n')
        subprocess.run([str(bin_dir / 'clang++'), '--version'], check=True)
        subprocess.run([str(bin_dir / 'cmake'), '--version'], check=True)
        subprocess.run([str(bin_dir / 'ninja'), '--version'], check=True)
        (cache / '.manifest').write_text(hashlib.sha256(b''.join((ROOT / name).read_bytes() for name in ('tools/toolchain/manifest.json', 'tools/bootstrap-cpp.py', 'tools/toolchain/source.py'))).hexdigest() + '\n')
        print(f'export PATH="{bin_dir}:$PATH"')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)
