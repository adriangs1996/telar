#!/usr/bin/env python3
import shutil
import subprocess

import check_http2_framing as framing


def build(root, arguments):
    artifacts = arguments.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=False)
    reference = arguments.reference.resolve()
    package = artifacts / 'reference'
    shutil.copytree(reference / 'src/backend/proxy', package / 'proxy')
    shutil.copyfile(root / 'tests/http2_capture_reference.zig', package / 'oracle.zig')
    for name in ['httprelay', 'exchangecapture', 'dropqueue', 'h2frames', 'cblocks', 'localca']:
        shutil.copytree(reference / 'lib' / name, package / name)
    shutil.copytree(reference / 'src/core', package / 'core')
    include = str(arguments.nghttp2 / 'include')
    library = str(arguments.nghttp2 / 'lib/libnghttp2.a')
    command = [arguments.zig, 'build-lib', '-dynamic', '-O', 'ReleaseFast', '-lc', library,
               '--dep', 'localca', '--dep', 'httprelay', '--dep', 'h2frames', '--dep', 'telar-core',
               '--dep', 'exchangecapture', '--dep', 'dropqueue', '-Mroot=' + str(package / 'oracle.zig'),
               '--dep', 'localca', '--dep', 'h2frames', '--dep', 'cblocks', '-I', include,
               '-Mhttprelay=' + str(package / 'httprelay/root.zig'),
               '-Mlocalca=' + str(package / 'localca/root.zig'),
               '-Mh2frames=' + str(package / 'h2frames/root.zig'),
               '-Mcblocks=' + str(package / 'cblocks/root.zig'),
               '-Mexchangecapture=' + str(package / 'exchangecapture/root.zig'),
               '-Mdropqueue=' + str(package / 'dropqueue/root.zig'),
               '-Mtelar-core=' + str(package / 'core/core.zig'),
               '-femit-bin=' + str(artifacts / 'zig.dylib')]
    with (artifacts / 'zig-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    command = [arguments.compiler, '-std=c++23', '-O3', '-dynamiclib', '-DTELAR_DEBUG=0',
               '-I', str(root), '-I', str(root.parents[1] / 'dlls/telar-client/include'), '-I', str(root.parents[1] / 'dlls/telar-base/include'), '-I', str(root.parents[1] / 'dlls/telar-lua/include'), '-I', str(root.parents[1] / 'dlls/telar-platform/include'), '-I', str(root.parents[1] / 'dlls/telar-plugins/include'), '-I', str(root.parents[1] / 'dlls/telar-config/include'), '-I', include, '-I', str(arguments.brotli / 'include'),
               '-I', str(arguments.zstd / 'include'), str(root / 'tests/http2_capture.cpp'),
               library, '-o', str(artifacts / 'cpp.dylib')]
    with (artifacts / 'cpp-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    return [framing.load_library(artifacts / name) for name in ['zig.dylib', 'cpp.dylib']]


def fixtures():
    yield from framing.fixtures()
    for response in [0, 1]:
        prefix = b'' if response else framing.PREFACE
        head = b'\x88' if response else b'\x82\x84'
        for count in [127, 128, 129, 255, 256, 257, 300]:
            for finished in [False, True]:
                data = prefix + b''.join(framing.frame(1, 5 if finished else 4, stream, head)
                                        for stream in range(1, count + 1))
                yield data, response, 16384, framing.UNLIMITED
        for status in [b'100', b'103', b'199', b'200', b'+4__00', b'65536']:
            data = prefix + framing.frame(1, 4, 1, framing.literal(b':status', status) +
                                          framing.literal(b'content-encoding', b'gzip'))
            data += framing.frame(1, 4, 1, head + framing.literal(b'CONTENT-ENCODING', b'identity'))
            data += framing.frame(0, 1, 1, b'captured body')
            yield data, response, 7, framing.UNLIMITED


def source_paths(root, arguments):
    paths = [root / 'tests/http2_capture.cpp', root / 'tests/http2_capture_reference.zig',
             root / 'tests/http2_oracle.hpp', root / 'tests/http2_oracle_stream.hpp',
             root / 'tests/capture_oracle.hpp', root / 'tools/check_http2_capture.py',
             root / 'tools/check_http2_framing.py']
    for folder in ['exchange_capture', 'http1', 'http2', 'memory', 'proxy', 'text']:
        paths.extend((root / folder).glob('*.hpp'))
    paths.extend((arguments.artifacts / 'reference').rglob('*.zig'))
    return paths


if __name__ == '__main__':
    framing.main(description='Compare HTTP/2 capture with the unchanged Zig transport adapters',
                 build_oracles=build, cases=fixtures, sources=source_paths)
