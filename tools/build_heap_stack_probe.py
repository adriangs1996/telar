"""Build a private native heap-site diagnostic; its timings never qualify wins."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from build_thread_cpu_probe import copy_typing_probe
from build_tab_switch_probe import build as build_switch_probe


def build(output, sampling=True, sample_shift=8, workload='typing'):
    if type(sample_shift) is not int or not 0 <= sample_shift <= 12:
        raise ValueError('Invalid heap sampling shift')
    if workload not in ('typing', 'tabs'):
        raise ValueError('Unsupported heap diagnostic workload')
    directory = Path(output).resolve()
    source = Path(__file__).resolve().parent
    if workload == 'tabs':
        build_switch_probe(directory)
        (directory / 'build.json').rename(directory / 'base-build.json')
    else:
        copy_typing_probe(directory, source)
    for name in ('heap_stack_census.h', 'heap_stack_census.c'):
        shutil.copy2(source / name, directory / name)
    path = directory / 'gui_tui_latency.m'
    contents = '#include "heap_stack_census.h"\n#include <dlfcn.h>\n' + path.read_text()

    def replace(before, after):
        nonlocal contents
        if contents.count(before) != 1:
            raise ValueError(f'Heap stack probe anchor changed: {before[:100]!r}')
        contents = contents.replace(before, after)

    helpers = '''
static HeapStackSnapshot heap_result;
static BOOL heap_started;

static NSString *heap_address(uint64_t address) {
    return [NSString stringWithFormat:@"0x%llx", (unsigned long long)address];
}

static NSDictionary *heap_stack_json(void) {
    NSMutableArray *records = [NSMutableArray array];
    NSMutableDictionary *symbols = [NSMutableDictionary dictionary];
    for (uint64_t index = 0; index < heap_result.used; ++index) {
        const HeapStackRecord *record = &heap_result.records[index];
        NSMutableArray *frames = [NSMutableArray array];
        for (uint64_t frame = 0; frame < record->depth; ++frame) {
            NSString *address = heap_address(record->frames[frame]);
            [frames addObject:address];
            if (!symbols[address]) {
                Dl_info info = {0};
                BOOL found = dladdr((void *)(uintptr_t)record->frames[frame], &info) != 0;
                symbols[address] = @{
                    @"resolved": @(found),
                    @"image": found && info.dli_fname ? [NSString stringWithUTF8String:info.dli_fname] : @"",
                    @"image_base": heap_address((uintptr_t)info.dli_fbase),
                    @"symbol": found && info.dli_sname ? [NSString stringWithUTF8String:info.dli_sname] : @"",
                    @"symbol_base": heap_address((uintptr_t)info.dli_saddr),
                };
            }
        }
        [records addObject:@{
            @"ordinal": @(record->ordinal), @"at_ns": @(record->at_ns),
            @"thread_id": @(record->thread_id), @"requested_bytes": @(record->requested_bytes),
            @"api": @(record->api), @"frames": frames,
        }];
    }
    NSMutableArray *apis = [NSMutableArray array];
    for (unsigned api = 0; api < heap_api_count; ++api) [apis addObject:@(heap_result.api_calls[api])];
    return @{
        @"version": @1, @"pid": @(getpid()), @"clock": @"CLOCK_UPTIME_RAW",
        @"complete": @(heap_result.complete), @"begin_ns": @(heap_result.begin_ns), @"end_ns": @(heap_result.end_ns),
        @"successful_calls": @(heap_result.successful_calls), @"null_returns": @(heap_result.null_returns),
        @"free_calls": @(heap_result.free_calls), @"requested_bytes": @(heap_result.requested_bytes),
        @"api_names": @[@"malloc", @"calloc", @"realloc", @"aligned_alloc", @"posix_memalign"], @"api_calls": apis,
        @"used": @(heap_result.used), @"overflow": @(heap_result.overflow), @"errors": @(heap_result.errors),
        @"sampling": @(heap_result.sampling), @"sample_shift": @(heap_result.sample_shift),
        @"records": records, @"symbols": symbols,
        @"scope": @"Diagnostic six-API results inside measured boundaries. Hash-sampled successful calls, bounded stacks, no live bytes or allocation CPU. Includes framework/probe work; excludes direct zones, uncovered APIs, fork children and observer-recursive calls. Serialized observation perturbs scheduling. Symbolization and result construction occur after observation ends.",
    };
}
'''
    replace('@interface ProbeFrame : NSObject {', helpers + '\n@interface ProbeFrame : NSObject {')
    replace('        getrusage(RUSAGE_SELF, &measurement_start_usage);',
            f'        if (telar_heap_stack_begin({sample_shift}, {"true" if sampling else "false"}) != 0) _exit(75);\n'
            '        heap_started = YES;\n        getrusage(RUSAGE_SELF, &measurement_start_usage);')
    replace('    finished=YES;',
            '    if (heap_started) {\n        if (telar_heap_stack_end(&heap_result) != 0) _exit(75);\n'
            '        heap_started = NO;\n    }\n    finished=YES;')
    replace('    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];',
            '    result[@"heap_stack_census"] = heap_stack_json();\n'
            '    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];')
    path.write_text(contents)
    commands = [
        ['clang', '-O2', '-Wall', '-Wextra', '-Werror', '-fno-omit-frame-pointer', '-c',
         str(directory / 'heap_stack_census.c'), '-o', str(directory / 'heap.o')],
        ['clang', '-dynamiclib', '-O2', '-fno-omit-frame-pointer', '-fobjc-arc',
         '-framework', 'AppKit', '-framework', 'QuartzCore', '-framework', 'Metal',
         str(path), str(directory / 'heap.o'), '-o', str(directory / 'probe.dylib')],
    ]
    with (directory / 'build.log').open('w') as log:
        for command in commands:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    shutil.copy2(__file__, directory / Path(__file__).name)
    (directory / 'build.json').write_text(json.dumps(dict(
        workload=workload, sampling=sampling, sample_shift=sample_shift, commands=commands,
        scope='Diagnostic only. Pair sampling with counts-only to assess observer interference; both include native probe work.',
        sha256={file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in directory.iterdir() if file.is_file()},
    ), indent=2) + '\n')
    return directory / 'probe.dylib'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--counts-only', action='store_true')
    parser.add_argument('--sample-shift', type=int, default=8)
    parser.add_argument('--workload', choices=('typing', 'tabs'), default='typing')
    options = parser.parse_args()
    print(build(options.output, not options.counts_only, options.sample_shift, options.workload))
