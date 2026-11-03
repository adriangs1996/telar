import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


RECIPE = '''cmake_minimum_required(VERSION 3.24)
project(qt_binding_storage_oracle LANGUAGES CXX)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(QT_NO_PRIVATE_MODULE_WARNING ON)
find_package(Qt6 REQUIRED COMPONENTS Gui GuiPrivate
  PATHS "${QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)
get_target_property(gui_library Qt6::Gui IMPORTED_LOCATION_RELEASE)
file(REAL_PATH "${QT_PREFIX}" checked_prefix)
file(REAL_PATH "${gui_library}" checked_library)
cmake_path(IS_PREFIX checked_prefix "${checked_library}" NORMALIZE managed)
if(NOT managed)
  message(FATAL_ERROR "QtGui resolved outside the requested prefix")
endif()
file(WRITE "${CMAKE_BINARY_DIR}/qt-library.txt" "${checked_library}")
add_executable(binding-oracle "${ORACLE_SOURCE}")
target_include_directories(binding-oracle PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_features(binding-oracle PRIVATE cxx_std_23)
target_compile_options(binding-oracle PRIVATE -Wall -Wextra -Werror)
target_link_libraries(binding-oracle PRIVATE Qt6::GuiPrivate)
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def candidate_header(source):
    start_marker = 'template<typename T>\nstruct QRhiBatchedBindings'
    end_marker = '\nclass QRhiGlobalObjectIdGenerator'
    if source.count(start_marker) != 1 or source.count(end_marker) != 1:
        raise ValueError('The Qt binding template changed; review this experiment before adapting it')
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    original = source[start:end]
    candidate = original.replace('QRhiBatchedBindings', 'InlineBindings')
    for before, after in (
        ('QVector<T> resources;', 'QVarLengthArray<T, inlineResourceCount> resources;'),
        ('QVector<Batch> batches;', 'QVarLengthArray<Batch, inlineBatchCount> batches;'),
        ('struct InlineBindings\n{',
         'struct InlineBindings\n{\n    static constexpr int inlineResourceCount = 4;\n'
         '    static constexpr int inlineBatchCount = 2;'),
    ):
        if candidate.count(before) != 1:
            raise ValueError(f'Unexpected Qt binding declaration: {before}')
        candidate = candidate.replace(before, after)
    copyright_lines = [line for line in source.splitlines()[:10]
                       if line.startswith('// Copyright') or line.startswith('// SPDX-License-Identifier:')]
    if len(copyright_lines) < 2:
        raise ValueError('Expected the Qt source copyright and license identifiers')
    header = '\n'.join(copyright_lines) + '\n#pragma once\n#include <QVarLengthArray>\n'
    return original, header + candidate + '\n'


def main():
    parser = argparse.ArgumentParser(description='Check experimental inline binding storage against the actual Qt private container')
    parser.add_argument('--qt-prefix', required=True, type=Path)
    parser.add_argument('--qt-header', required=True, type=Path,
                        help='qrhi_p.h from the matching Qt source or installation')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--compiler', type=Path)
    parser.add_argument('--sanitize', action='store_true')
    options = parser.parse_args()
    prefix = options.qt_prefix.resolve(strict=True)
    header = options.qt_header.resolve(strict=True)
    original, candidate = candidate_header(header.read_text())
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    oracle = Path(__file__).with_name('qt_binding_storage_oracle.cpp').resolve()
    (output / 'inline_bindings.hpp').write_text(candidate)
    (output / 'CMakeLists.txt').write_text(RECIPE)
    command = ['cmake', '-S', str(output), '-B', str(output / 'build'), '-G', 'Ninja',
               '-DCMAKE_BUILD_TYPE=Release', f'-DQT_PREFIX={prefix}', f'-DORACLE_SOURCE={oracle}']
    if options.compiler:
        compiler = options.compiler.absolute()
        if not compiler.is_file():
            raise ValueError(f'C++ compiler does not exist: {compiler}')
        command.append(f'-DCMAKE_CXX_COMPILER={compiler}')
    if options.sanitize:
        command.append('-DCMAKE_CXX_FLAGS_RELEASE=-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer')
    environment = os.environ.copy()
    for name in ('DYLD_INSERT_LIBRARIES', 'DYLD_FRAMEWORK_PATH', 'DYLD_LIBRARY_PATH', 'LD_PRELOAD', 'LD_LIBRARY_PATH'):
        environment.pop(name, None)
    manifest = dict(command=command, qt_prefix=str(prefix), qt_header=str(header),
                    qt_header_sha256=digest(header), oracle_sha256=digest(oracle),
                    reference_template_sha256=hashlib.sha256(original.encode()).hexdigest(),
                    candidate_header_sha256=digest(output / 'inline_bindings.hpp'),
                    sanitized=options.sanitize,
                    scope='Container output, copying, clearing and dynamic fallback only; no native Metal or performance acceptance')
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for name, arguments in (
        ('configure', command),
        ('build', ['cmake', '--build', str(output / 'build'), '--target', 'binding-oracle']),
        ('oracle', [str(output / 'build/binding-oracle')]),
    ):
        with (output / f'{name}.stdout').open('w') as stdout, (output / f'{name}.stderr').open('w') as stderr:
            subprocess.run(arguments, env=environment, stdout=stdout, stderr=stderr, check=True)
    result = json.loads((output / 'oracle.stdout').read_text())
    if result.get('passed') is not True or result.get('cases') != 4123:
        raise ValueError('The oracle did not complete its declared workload')
    library = Path((output / 'build/qt-library.txt').read_text())
    manifest.update(qt_gui_path=str(library), qt_gui_sha256=digest(library),
                    oracle_binary_sha256=digest(output / 'build/binding-oracle'))
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
