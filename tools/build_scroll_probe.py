"""Build an isolated upward-scroll probe with exact visible-row packet checks."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from build_thread_cpu_probe import copy_typing_probe


def build(output):
    directory = Path(output).resolve()
    source = Path(__file__).resolve().parent
    copy_typing_probe(directory, source)
    for name in ('scroll_bench_fixture.py', 'scroll_bench_report.py', 'scroll_probe.inc', 'tab_switch_packet.py', 'tab_switch_packet.h'):
        shutil.copy2(source / name, directory / name)
    path = directory / 'gui_tui_latency.py'
    contents = path.read_text()
    anchor = "Path(__file__).with_name('terminal_bench_fixture.py').resolve()"
    if contents.count(anchor) != 1:
        raise ValueError('Scroll fixture anchor changed')
    contents = contents.replace(anchor, "Path(__file__).with_name('scroll_bench_fixture.py').resolve()")
    guard = "    runtime = runtime_program(mode, getattr(options, 'cpp_runtime', None))"
    if contents.count(guard) != 1:
        raise ValueError('Scroll measurement guard anchor changed')
    contents = contents.replace(guard,
        "    if (mode != 'gui-cpp' or getattr(options, 'case', None) != 'single' or\n"
        "            options.endpoint != 'presented' or\n"
        "            options.image_size or options.throughput):\n"
        "        raise ValueError('Scroll probe requires one stationary pane and native presentation')\n" + guard)
    additions = {
        "    modes = MODE_GROUPS.get(options.mode, [options.mode])":
            "    modes = MODE_GROUPS.get(options.mode, [options.mode])\n"
            "    if (any(mode != 'gui-cpp' for mode in modes) or options.cases != ['single'] or\n"
            "            options.endpoint != 'presented' or\n"
            "            options.image_size or options.throughput or options.text_pattern != 'repeat'):\n"
            "        parser.error('Scroll probe requires Telar-only modes, --cases single, --endpoint presented and no other workload')",
        "def measure(mode, directory, setup):":
            "from scroll_bench_report import validate_scroll\n\ndef measure(mode, directory, setup):",
        "        result['case'] = case": "        result['case'] = 'scroll'",
        "    (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\\n')":
            "    result['scroll_validation'] = validate_scroll(result, json.loads((directory / 'scroll.json').read_text()),\n"
            "                                                  int((directory / 'primary.claim').read_text()))\n"
            "    (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\\n')",
        "aggregate=aggregate_runs(results, options.cases, modes)":
            "aggregate=aggregate_runs(results, ['scroll'], modes)",
        "input_method='key', cases=options.cases, panes=options.panes,":
            "input_method='native_discrete_wheel', cases=['scroll'], layout_cases=options.cases, panes=1,",
        "'kitty_stream.py', 'terminal_bench_report.py', 'bench_stack.py', 'benchmark_host.py')}":
            "'kitty_stream.py', 'terminal_bench_report.py', 'bench_stack.py', 'benchmark_host.py',\n"
            "                                             'scroll_bench_fixture.py', 'scroll_bench_report.py', 'scroll_probe.inc',\n"
            "                                             'tab_switch_packet.py', 'tab_switch_packet.h')}",
    }
    for before, after in additions.items():
        if contents.count(before) != 1:
            raise ValueError(f'Scroll validation anchor changed: {before}')
        contents = contents.replace(before, after)
    path.write_text(contents)
    path = directory / 'gui_tui_latency.m'
    contents = path.read_text()

    def replace(before, after):
        nonlocal contents
        if contents.count(before) != 1:
            raise ValueError(f'Scroll probe anchor changed: {before[:100]}')
        contents = contents.replace(before, after)

    replace('#include "gui_view.h"', '#include "gui_view.h"\n#include "tab_switch_packet.h"')
    replace('@interface ProbeFrame : NSObject {', '#include "scroll_probe.inc"\n\n@interface ProbeFrame : NSObject {')
    replace('@public unsigned sequence, geometry; NSUInteger drawable_id;', '@public unsigned sequence, geometry, visible_row; NSUInteger drawable_id;')
    replace('    pending=YES;\n    atomic_store(&epoch,(unsigned)count+1);',
            '    if (!scroll_top_row) { finish(12); return; }\n'
            '    scroll_expected[count] = scroll_top_row - 3 * ((unsigned)count + 1);\n'
            '    pending=YES;\n    atomic_store(&epoch,(unsigned)count+1);')
    replace('    began=CACurrentMediaTime();', '    began=CACurrentMediaTime();\n    scroll_input_at[count] = began;')
    start = contents.index('    if(text_input){\n        [(id<NSTextInputClient>)target insertText:')
    end = contents.index('    unsigned sequence = (unsigned)count + 1;', start)
    contents = contents[:start] + '    if (!inject_scroll(view)) { finish(ProbeFailureInputTarget); return; }\n' + contents[end:]
    replace('    pending=NO;count++;',
            '    scroll_observed[count] = frame->visible_row;\n'
            '    scroll_presented_at[count] = frame->presented;\n    pending=NO;count++;')
    replace('    r->width = pixel_only ? 1 : texture.width;',
            '    r->width = pixel_only ? TabPacketCells * atomic_load(&scroll_cell_width) : texture.width;\n'
            '    if (r->x + r->width > texture.width) return nil;')
    replace('        NSUInteger sx = 0, sy = 0, n = 0;',
            '        NSUInteger sx = 0, sy = 0, n = 0, first_x = r->width, last_x = 0, first_y = r->height;')
    replace('                    sx += col; sy += row; n++;',
            '                    sx += col; sy += row; n++;\n'
            '                    first_x = MIN(first_x, col); last_x = MAX(last_x, col); first_y = MIN(first_y, row);')
    replace('            marker_x = sx/n; marker_y = sy/n;',
            '            marker_x = sx/n; marker_y = first_y + 1;\n'
            '            atomic_store(&scroll_cell_width, last_x - first_x + 1);')
    replace('            r->frame->verified = YES;\n            accept_frame(r->frame);',
            '            r->frame->verified = NO;\n            accept_frame(r->frame);')
    replace('        int value = color(p);',
            '        TabPacket packet = {0};\n'
            '        BOOL packet_valid = tab_packet_decode(p, r->pitch, atomic_load(&scroll_cell_width) * 4, &packet);\n'
            '        int value = packet_valid ? (int)packet.generation : -1;')
    replace('            r->frame->verified = value == (int)(r->frame->sequence & 1);',
            '            unsigned sequence = r->frame->sequence;\n'
            '            r->frame->visible_row = packet.generation;\n'
            '            r->frame->verified = packet_valid && packet.tab == 0 && (sequence == 0 ?\n'
            '                scroll_fixture_ready() && packet.generation == scroll_top_row :\n'
            '                sequence <= ProbeSampleCapacity && packet.generation == scroll_expected[sequence - 1]);')
    replace('    NSMutableArray *gpu = [NSMutableArray array], *work = [NSMutableArray array];',
            '    NSMutableArray *scroll_samples = [NSMutableArray array];\n'
            '    NSMutableArray *gpu = [NSMutableArray array], *work = [NSMutableArray array];')
    replace('        [gpu addObject:@(gpu_samples[i])];',
            '        [scroll_samples addObject:@{@"expected_row": @(scroll_expected[i]), @"observed_row": @(scroll_observed[i]),\n'
            '            @"input_at": @(scroll_input_at[i]), @"presented_at": @(scroll_presented_at[i])}];\n'
            '        [gpu addObject:@(gpu_samples[i])];')
    replace('        @"marker": @[@(marker_x), @(marker_y)], @"gpu_ms": gpu, @"gpu_work_ms": work,',
            '        @"scroll_samples": scroll_samples, @"scroll_initial_top_row": @(scroll_top_row),\n'
            '        @"scroll_rows_per_input": @3, @"packet_cell_width": @(scroll_cell_width), @"interaction": @"scroll_up",\n'
            '        @"marker": @[@(marker_x), @(marker_y)], @"gpu_ms": gpu, @"gpu_work_ms": work,')
    replace('@"input_method": text_input ? @"text" : @"key",', '@"input_method": @"native_discrete_wheel",')
    path.write_text(contents)
    command = ['clang', '-dynamiclib', '-O2', '-fobjc-arc', '-framework', 'AppKit',
               '-framework', 'QuartzCore', '-framework', 'Metal', str(path), '-o', str(directory / 'probe.dylib')]
    result = subprocess.run(command, capture_output=True, text=True)
    (directory / 'build.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    shutil.copy2(__file__, directory / Path(__file__).name)
    (directory / 'build.json').write_text(json.dumps(dict(
        command=command, scope='Stationary scrollback, discrete native wheel input to exact top-row packet presentation; no continuous-cadence or selection qualification.',
        sha256={file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in directory.iterdir() if file.is_file()},
    ), indent=2) + '\n')
    return directory / 'probe.dylib'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    print(build(parser.parse_args().output))
