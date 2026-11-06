"""Source bootstrap for hosts without official LLVM binaries (including musl).

Uses the same verified archives as the binary bootstrap. The initial native
compiler, CMake, make, Perl and Python are development tools supplied by the SDK.
No application library is taken from this initial toolchain's installation.
"""
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def build(manifest, cache, prepare, root, jobs):
    host = [platform.system(), platform.machine(), os.environ.get('CC', 'cc'),
            os.environ.get('CXX', 'c++'), os.environ.get('CFLAGS', ''),
            os.environ.get('CXXFLAGS', ''), os.environ.get('LDFLAGS', '')]
    for compiler in (os.environ.get('CC', 'cc'), os.environ.get('CXX', 'c++')):
        host.append(subprocess.check_output([compiler, '--version'], text=True))
    if platform.system() == 'Darwin':
        for option in ('--show-sdk-path', '--show-sdk-build-version'):
            host.append(subprocess.check_output(['xcrun', '--sdk', 'macosx', option], text=True))
    identity = hashlib.sha256('\n'.join(host).encode() + (root / 'tools/toolchain/manifest.json').read_bytes()
                              + Path(__file__).read_bytes()
                              + (root / 'cmake/openssl/manifest.cmake').read_bytes()
                              + (root / 'cmake/openssl/CMakeLists.txt').read_bytes()).hexdigest()[:16]
    prefix = cache / ('source-' + identity)
    if (prefix / '.complete').exists():
        return prefix
    prefix.mkdir(exist_ok=True)
    sources = {tool: prepare(tool + '-source', manifest['artifacts'][tool]['source'], cache)
               for tool in ('cmake', 'ninja', 'llvm')}
    # CMake's own HTTPS transport needs OpenSSL. Reuse Telar's pinned recipe,
    # using the SDK CMake only to bootstrap the newest CMake from source.
    openssl = prefix / 'openssl'
    run('cmake', '-S', root / 'cmake/openssl', '-B', openssl, '-G', 'Unix Makefiles',
        '-DTELAR_MANAGED_JOBS=' + str(jobs))
    run('cmake', '--build', openssl, '--target', 'telar-openssl', '-j', jobs)
    cmake_build = prefix / 'cmake-build'
    cmake_build.mkdir(exist_ok=True)
    run(sources['cmake'] / 'bootstrap', '--prefix=' + str(prefix), '--parallel=' + str(jobs),
        '--', '-DCMAKE_BUILD_TYPE=Release', '-DOPENSSL_USE_STATIC_LIBS=ON',
        '-DOPENSSL_ROOT_DIR=' + str(openssl / 'install'), cwd=cmake_build)
    run('make', '-j', jobs, cwd=cmake_build)
    run('make', 'install', cwd=cmake_build)
    ninja_build = prefix / 'ninja-build'
    if not ninja_build.exists():
        shutil.copytree(sources['ninja'], ninja_build)
    run('python3', 'configure.py', '--bootstrap', cwd=ninja_build)
    shutil.copy2(ninja_build / 'ninja', prefix / 'bin/ninja')
    options = ['-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_INSTALL_PREFIX=' + str(prefix),
               '-DCMAKE_MAKE_PROGRAM=' + str(prefix / 'bin/ninja'),
               '-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra;lld',
               '-DLLVM_BUILD_LLVM_DYLIB=ON', '-DLLVM_LINK_LLVM_DYLIB=ON',
               '-DCLANG_LINK_CLANG_DYLIB=ON',
               '-DLLVM_TARGETS_TO_BUILD=Native', '-DLLVM_INCLUDE_TESTS=OFF',
               '-DLLVM_INCLUDE_BENCHMARKS=OFF', '-DLLVM_ENABLE_ZLIB=OFF',
               '-DLLVM_ENABLE_ZSTD=OFF', '-DLLVM_ENABLE_LIBXML2=OFF',
               '-DLLVM_ENABLE_LIBEDIT=OFF', '-DLLVM_ENABLE_TERMINFO=OFF']
    if platform.system() == 'Linux':
        options += ['-DLLVM_ENABLE_RUNTIMES=compiler-rt;libunwind;libcxxabi;libcxx',
                    '-DLIBCXX_ENABLE_SHARED=OFF', '-DLIBCXXABI_ENABLE_SHARED=OFF',
                    '-DLIBUNWIND_ENABLE_SHARED=OFF', '-DLIBCXXABI_USE_LLVM_UNWINDER=ON',
                    '-DLIBCXX_HAS_MUSL_LIBC=' + ('ON' if list(Path('/lib').glob('ld-musl-*')) else 'OFF')]
    run(prefix / 'bin/cmake', '-S', sources['llvm'] / 'llvm', '-B', prefix / 'llvm-build', '-G', 'Ninja', *options)
    run(prefix / 'bin/cmake', '--build', prefix / 'llvm-build', '--target', 'install', '-j', jobs)
    (prefix / '.complete').write_text(identity + '\n')
    return prefix
