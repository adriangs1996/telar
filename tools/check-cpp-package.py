#!/usr/bin/env python3
"""Install telar-base privately and compile a consumer from the installed sources."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    args = parser.parse_args()
    build = args.build.resolve()
    cache = dict(line.split('=', 1) for line in (build / 'CMakeCache.txt').read_text().splitlines()
                 if '=' in line and not line.startswith(('#', '//')))
    configuration = cache['CMAKE_BUILD_TYPE:STRING']
    cmake = ROOT / '.toolchain/bin/cmake'
    chain = ROOT / '.toolchain/toolchain.cmake'
    env = dict(os.environ, PATH=str(cmake.parent) + os.pathsep + os.environ['PATH'])
    def run(*arguments, **kwargs):
        return subprocess.run([str(arg) for arg in arguments], env=env, check=True, **kwargs)
    with tempfile.TemporaryDirectory(prefix='telar-base-consumer-') as directory:
        directory = Path(directory)
        stage, source, consumer = (directory / name for name in ('stage', 'source', 'build'))
        run(cmake, '--install', build, '--prefix', stage)
        if list(stage.rglob('*.pcm')) or list(stage.rglob('*.bmi')):
            raise RuntimeError('The package must distribute sources, not local BMIs')
        source.mkdir()
        (source / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 4.4.5)
project(telar_base_consumer LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 23)
find_package(telar-base CONFIG REQUIRED)
add_executable(consumer main.cpp)
target_link_libraries(consumer PRIVATE telar::base)
''')
        (source / 'main.cpp').write_text('''#include <string_view>
import telar.base.text;
int main() {
  return telar::runtime::unsignedDecimal<unsigned>("42").value_or(0) == 42 &&
         telar::runtime::JsonValue{"[1]"}.encoded() == "[1]" ? 0 : 1;
}
''')
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
