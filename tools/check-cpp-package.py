#!/usr/bin/env python3
"""Install a module package privately and compile an external source consumer."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--package', choices=('base', 'websock'), default='base')
    args = parser.parse_args()
    package = 'telar-base' if args.package == 'base' else 'websock'
    target = 'telar::base' if args.package == 'base' else 'telar::websock'
    build = args.build.resolve()
    cache = dict(line.split('=', 1) for line in (build / 'CMakeCache.txt').read_text().splitlines()
                 if '=' in line and not line.startswith(('#', '//')))
    configuration = cache['CMAKE_BUILD_TYPE:STRING']
    cmake = ROOT / '.toolchain/bin/cmake'
    chain = ROOT / '.toolchain/toolchain.cmake'
    env = dict(os.environ, PATH=str(cmake.parent) + os.pathsep + os.environ['PATH'])
    def run(*arguments, **kwargs):
        return subprocess.run([str(arg) for arg in arguments], env=env, check=True, **kwargs)
    with tempfile.TemporaryDirectory(prefix='telar-module-consumer-') as directory:
        directory = Path(directory)
        stage, source, consumer = (directory / name for name in ('stage', 'source', 'build'))
        run(cmake, '--install', build, '--prefix', stage)
        if list(stage.rglob('*.pcm')) or list(stage.rglob('*.bmi')):
            raise RuntimeError('The package must distribute sources, not local BMIs')
        source.mkdir()
        (source / 'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 4.4.5)
project(telar_module_consumer LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 23)
find_package({package} CONFIG REQUIRED)
add_executable(consumer main.cpp)
target_link_libraries(consumer PRIVATE {target})
''')
        base_consumer = '''#include <string_view>
import telar.base.text;
int main() {
  return telar::runtime::unsignedDecimal<unsigned>("42").value_or(0) == 42 &&
         telar::runtime::JsonValue{"[1]"}.encoded() == "[1]" ? 0 : 1;
}
'''
        websock_consumer = '''#include <telar_base/memory/allocator.hpp>
import telar.websock;
template <typename Memory>
concept ServerMemory = requires { typename telar::websock::Server<Memory>; };
static_assert(ServerMemory<telar::SystemAllocator>);
static_assert(!ServerMemory<int>);
int main() { return 0; }
'''
        (source / 'main.cpp').write_text(base_consumer if args.package == 'base' else websock_consumer)
        options = ['-G', 'Ninja', '-DCMAKE_TOOLCHAIN_FILE=' + str(chain), '-DCMAKE_PREFIX_PATH=' + str(stage)]
        run(cmake, '-S', source, '-B', consumer, '-DCMAKE_BUILD_TYPE=' + configuration, *options)
        run(cmake, '--build', consumer, '--parallel', '2')
        run(consumer / 'consumer')
        if not list(consumer.rglob('*.pcm')) and not list(consumer.rglob('*.bmi')):
            raise RuntimeError('The consumer did not rebuild its BMIs')
        other = 'Release' if configuration == 'Debug' else 'Debug'
        failure = subprocess.run([str(cmake), '-S', str(source), '-B', str(directory / 'mismatch'),
                                  '-DCMAKE_BUILD_TYPE=' + other, *options], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if failure.returncode == 0 or 'archive was built as' not in failure.stdout:
            raise RuntimeError('An incompatible installed configuration was accepted: ' + failure.stdout)
        print('Installed source imports, local BMI rebuild and configuration guard passed')


if __name__ == '__main__':
    main()
