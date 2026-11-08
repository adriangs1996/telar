#!/usr/bin/env python3
"""Build an isolated native tab-switch probe from the checked-in latency harness.

Exact source anchors fail closed when that harness changes. The ordinary typing
probe is untouched. Generated code, dependencies and hashes stay in a new output
directory so a run can be reproduced without modifying the installed GUI.
Only the first warmup input is phase-scheduled; subsequent inputs and the four
producer loops remain unchanged.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

def build(output):
    directory = Path(output).resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    source = Path(__file__).resolve().parent
    for name in ('gui_tui_latency.py', 'gui_tui_latency.m', 'gui_view.h', 'terminal_bench_fixture.py', 'tab_switch_fixture.py', 'tab_switch_packet.py', 'tab_switch_packet.h', 'tab_switch_phase.h', 'tab_switch_phase.inc', 'tab_switch_clock.c', 'terminal_bench_report.py', 'bench_stack.py', 'image_bench_fixture.py', 'image_patterns.py', 'kitty_stream.py'):
        shutil.copy2(source / name, directory / name)
    path = directory / 'gui_tui_latency.py'
    contents = path.read_text()
    fixture_anchor = "Path(__file__).with_name('terminal_bench_fixture.py').resolve()"
    if contents.count(fixture_anchor) != 1:
        raise ValueError('Native harness fixture anchor changed')
    contents = contents.replace(fixture_anchor, "Path(__file__).with_name('tab_switch_fixture.py').resolve()")
    path.write_text(contents)
    path = directory / 'gui_tui_latency.m'
    contents = path.read_text()

    def replace(old, new):
        nonlocal contents
        if contents.count(old) != 1:
            raise ValueError(f'Native probe source changed: expected one anchor {old[:80]!r}')
        contents = contents.replace(old, new)
    replace('#include "gui_view.h"', '#include "gui_view.h"\n#include "tab_switch_packet.h"\n#include "tab_switch_phase.h"')
    replace('static BOOL pending, finished, text_input;', 'static BOOL pending, finished, text_input;\n    static atomic_ulong packet_cell_width;\n    static TabPhasePlan switch_phase;\n    static BOOL switch_phase_started;\n    static dispatch_source_t switch_phase_timer;\n    static unsigned expected_tabs[ProbeSampleCapacity], minimum_generations[ProbeSampleCapacity];\n    static unsigned observed_tabs[ProbeSampleCapacity], observed_generations[ProbeSampleCapacity];\n    static unsigned last_seen_generations[16];\n    static double switch_input_at[ProbeSampleCapacity], switch_presented_at[ProbeSampleCapacity];\n    static BOOL layout_key(BOOL create);')
    replace('@public unsigned sequence, geometry; NSUInteger drawable_id;', '@public unsigned sequence, geometry, tab_index, content_generation; NSUInteger drawable_id;')
    replace('    pending=YES;\n    atomic_store(&epoch,(unsigned)count+1);', '    unsigned wanted = panes - 1 - (unsigned)count % panes;\n        NSString *receipt_path = [display_directory stringByAppendingPathComponent:[NSString stringWithFormat:@"switching/%u.json", wanted]];\n        NSData *receipt_data = [NSData dataWithContentsOfFile:receipt_path];\n        NSDictionary *receipt = receipt_data ? [NSJSONSerialization JSONObjectWithData:receipt_data options:0 error:nil] : nil;\n        unsigned generation = [receipt[@"generation"] unsignedIntValue];\n        if (![receipt[@"phase"] isEqualToString:@"ready"] || !generation || [receipt[@"tab_index"] unsignedIntValue] != wanted) { finish(12); return; }\n        expected_tabs[count] = wanted;\n        minimum_generations[count] = MAX(generation, last_seen_generations[wanted] + 1);\n        pending=YES;\n        atomic_store(&epoch,(unsigned)count+1);')
    replace('static void send_key(void) {', '#include "tab_switch_phase.inc"\n\nstatic void send_key(void) {')
    replace('    if(finished)return;\n    NSSize scene', '    if(finished)return;\n    if (!count && !switch_phase_started) {\n        if (!schedule_switch_start()) finish(ProbeFailureSetupTimeout);\n        return;\n    }\n    NSSize scene')
    input_begin = '    if(text_input){\n        [(id<NSTextInputClient>)target insertText:'
    input_end = '    unsigned sequence = (unsigned)count + 1;'
    if contents.count(input_begin) != 1 or contents.count(input_end) != 1:
        raise ValueError('Native probe input injection anchors changed')
    a = contents.index(input_begin)
    b = contents.index(input_end, a)
    contents = contents[:a] + '    if (!layout_key(NO)) { finish(ProbeFailureInputTarget); return; }\n' + contents[b:]
    replace('    began=CACurrentMediaTime();', '    began=CACurrentMediaTime();\n    switch_input_at[count] = began;')
    replace('    pending=NO;count++;', '    switch_presented_at[count] = frame->presented;\n        observed_tabs[count] = frame->tab_index;\n        observed_generations[count] = frame->content_generation;\n        last_seen_generations[frame->tab_index] = frame->content_generation;\n        pending=NO;count++;')
    replace('    r->width = pixel_only ? 1 : texture.width;', '    r->width = pixel_only ? TabPacketCells * atomic_load(&packet_cell_width) : texture.width;\n    if (r->x + r->width > texture.width) return nil;')
    replace('        NSUInteger sx = 0, sy = 0, n = 0;', '        NSUInteger sx = 0, sy = 0, n = 0, first_x = r->width, last_x = 0;')
    replace('                    sx += col; sy += row; n++;', '                    sx += col; sy += row; n++;\n                    first_x = MIN(first_x, col); last_x = MAX(last_x, col);')
    replace('            marker_x = sx/n; marker_y = sy/n;', '            marker_x = sx/n; marker_y = sy/n;\n            atomic_store(&packet_cell_width, last_x - first_x + 1);')
    replace('            r->frame->verified = YES;\n            accept_frame(r->frame);', '            r->frame->verified = NO;\n            accept_frame(r->frame);')
    replace('        int value = color(p);', '        TabPacket packet = {0};\n        BOOL packet_valid = tab_packet_decode(p, r->pitch, atomic_load(&packet_cell_width) * 4, &packet);\n        int value = packet_valid ? (int)packet.tab : -1;')
    replace('            r->frame->verified = value == (int)(r->frame->sequence & 1);', '            unsigned sequence = r->frame->sequence;\n                r->frame->tab_index = packet.tab;\n                r->frame->content_generation = packet.generation;\n                r->frame->verified = packet_valid && (sequence == 0 ? packet.tab == 0 :\n                    sequence <= ProbeSampleCapacity && packet.tab == expected_tabs[sequence - 1] &&\n                    packet.generation >= minimum_generations[sequence - 1]);')
    replace('    NSMutableArray *gpu = [NSMutableArray array], *work = [NSMutableArray array];', '    NSMutableArray *switch_samples = [NSMutableArray array];\n    NSMutableArray *gpu = [NSMutableArray array], *work = [NSMutableArray array];')
    replace('        [gpu addObject:@(gpu_samples[i])];', '        [switch_samples addObject:@{@"target_tab": @(expected_tabs[i]), @"minimum_generation": @(minimum_generations[i]),\n                @"observed_tab": @(observed_tabs[i]), @"observed_generation": @(observed_generations[i]),\n                @"input_at": @(switch_input_at[i]), @"presented_at": @(switch_presented_at[i])}];\n            [gpu addObject:@(gpu_samples[i])];')
    replace('        @"marker": @[@(marker_x), @(marker_y)], @"gpu_ms": gpu, @"gpu_work_ms": work,', '        @"switch_samples": switch_samples, @"packet_cell_width": @(packet_cell_width), @"interaction": @"previous_tab",\n        @"marker": @[@(marker_x), @(marker_y)], @"gpu_ms": gpu, @"gpu_work_ms": work,')
    replace('        @"switch_samples": switch_samples,', '        @"initial_phase": @{@"policy": @"widest_producer_gap", @"deadline": @(switch_phase.deadline), @"clearance": @(switch_phase.clearance)},\n        @"switch_samples": switch_samples,')
    path.write_text(contents)
    clock_command = ['clang', '-dynamiclib', '-O2', '-Wall', '-Wextra', '-Werror',
                     str(directory / 'tab_switch_clock.c'), '-o', str(directory / 'tab_switch_clock.dylib')]
    subprocess.run(clock_command, check=True)
    command = ['clang', '-dynamiclib', '-O2', '-fobjc-arc', '-framework', 'AppKit', '-framework', 'QuartzCore', '-framework', 'Metal', str(path), '-o', str(directory / 'probe.dylib')]
    result = subprocess.run(command, capture_output=True, text=True)
    (directory / 'build.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    shutil.copy2(__file__, directory / 'build_tab_switch_probe.py')
    (directory / 'build.json').write_text(json.dumps({'command': command, 'clock_command': clock_command, 'sha256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in directory.iterdir() if path.suffix in ('.py', '.h', '.m', '.c', '.inc', '.dylib')}}, indent=2) + '\n')
    return directory / 'probe.dylib'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New private build directory')
    args = parser.parse_args()
    build(args.output)
if __name__ == '__main__':
    main()
