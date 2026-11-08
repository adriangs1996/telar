#!/usr/bin/env python3
"""Compare isolated plugin-worker effects against exact bytes and the Zig worker.

This is a functional oracle. It never starts a runtime or contacts a real GUI.
Pass --zig for differential checks, or omit it to check the C++ worker alone.
Pass --output to retain generated sources and receipts; otherwise they are temporary.
"""
import argparse
import contextlib
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile


def fixtures():
    cases = []

    def add(name, body, expected, **options):
        cases.append(dict(name=name, source="local t=require('telar'); return {actions={run=function(ctx) " + body + " end}}", expected=expected, **options))

    simple = dict(toggle_sidebar=3, close_pane=4, new_tab=5, rename_tab=8,
                  close_tab=9, detach=11, toggle_pane_fullscreen=13,
                  toggle_workspace_list=14, new_workspace=15,
                  rename_workspace=16, leave_worktree=20)
    for action, tag in simple.items():
        add(action, f"return t.action.{action}()", bytes([1, tag]))
    for action, tag, directions in (
            ('split_pane', 1, ('horizontal', 'vertical')),
            ('focus_pane', 2, ('left', 'right', 'up', 'down')),
            ('resize_pane', 12, ('left', 'right', 'up', 'down')),
            ('move_tab', 10, ('previous', 'next')),
            ('resize_sidebar', 19, ('left', 'right'))):
        for index, direction in enumerate(directions):
            add(action + '_' + direction, f"return t.action.{action}{{direction='{direction}'}}", bytes([1, tag, index]))
    for action, tag in (('select_tab', 7), ('select_workspace', 17)):
        for index in (1, 256):
            add(action + '_' + str(index), f"return t.action.{action}{{index={index}}}", bytes([1, tag, index - 1]))
    for offset in (-128, 0, 127):
        add('offset_' + str(offset), f"return t.action.select_tab_offset{{offset={offset}}}", bytes([1, 6, offset & 255]))
    add('context', "assert(ctx.sidebar_visible and ctx.tab_count==3 and ctx.active_tab_index==2 and ctx.pane_count==2 and ctx.focused_pane_id==42); return t.action.toggle_sidebar()", bytes([1, 3]))
    add('readonly_context', "ctx.tab_count=99; return t.action.toggle_sidebar()", None)
    add('empty_batch', 'return {}', bytes([0]))
    add('ordered_batch', 'return {t.action.new_tab(), t.action.toggle_sidebar(), t.action.close_tab()}', bytes([3, 5, 3, 9]))
    add('bounded_batch', 'local result={}; for i=1,16 do result[i]=t.action.toggle_sidebar() end; result[17]=function()end; return result', bytes([16] + [3] * 16))
    add('local_module', "local h=require('config.helper'); return h.action()", bytes([1, 3]), files={'config/helper.lua': "local t=require('telar'); return {action=function()return t.action.toggle_sidebar()end}"})
    title, body = 'Hello 🦀', 'Body 漢字'
    for name, target_tag in (('none', 0), ('pane_id', 1), ('tab_id', 2), ('workspace_id', 3)):
        target = '' if name == 'none' else f', {name}=42'
        expected = bytes([1, 18, 2]) + struct.pack('<I', 3000) + bytes([target_tag])
        if target_tag:
            expected += struct.pack('<Q', 42)
        for value in (title, body):
            encoded = value.encode()
            expected += struct.pack('<H', len(encoded)) + encoded
        add('notification_' + name, f"return t.action.notification{{title='{title}', body='{body}', level='warning', duration_ms=3000{target}}}", expected)
    for name, body in (
            ('nil_result', 'return nil'),
            ('recursive_effect', 'return {function()end}'),
            ('unsupported_effect', "return t.action.scroll_pane{direction='up'}"),
            ('invalid_direction', "return t.action.focus_pane{direction='outside'}"),
            ('invalid_index', 'return t.action.select_tab{index=257}'),
            ('two_targets', "return t.action.notification{title='x',pane_id=1,tab_id=2}"),
            ('callback_error', "error('intentional callback error')"),
            ('instruction_limit', 'while true do end'),
            ('memory_limit', "local x=string.rep('x',300*1024*1024); return {}")):
        add(name, body, None)
    add('sandbox', "local names={}; for name in pairs(os) do names[#names+1]=name end; table.sort(names); assert(table.concat(names,',')=='clock,date,time' and io==nil and debug==nil and loadfile==nil and dofile==nil and rawset==nil); return {}", bytes([0]))
    for name, context in (
            ('invalid_bool', ['2', '3', '1', '2', '42']),
            ('tab_count_overflow', ['1', '65536', '1', '2', '42']),
            ('active_index_overflow', ['1', '3', '65536', '2', '42']),
            ('pane_count_overflow', ['1', '3', '1', '65536', '42']),
            ('pane_id_overflow', ['1', '3', '1', '2', '18446744073709551616']),
            ('negative_count', ['1', '-1', '1', '2', '42']),
            ('missing_argument', ['1', '3', '1', '2']),
            ('extra_argument', ['1', '3', '1', '2', '42', '0'])):
        add(name, 'return {}', None, context=context)
    for action, tag in simple.items():
        add('builtin_' + action, f"return {{'{action.replace('_', '-')}'}}", bytes([1, tag]))
    for name, tag, directions in (
            ('split', 1, ('horizontal', 'vertical')),
            ('focus', 2, ('left', 'right', 'up', 'down')),
            ('resize', 12, ('left', 'right', 'up', 'down')),
            ('move-tab', 10, ('previous', 'next')),
            ('resize-sidebar', 19, ('left', 'right'))):
        for index, direction in enumerate(directions):
            add('builtin_' + name + '_' + direction, f"return {{'{name}-{direction}'}}", bytes([1, tag, index]))
    add('builtin_next_tab', "return {'next-tab'}", bytes([1, 6, 1]))
    add('builtin_previous_tab', "return {'previous-tab'}", bytes([1, 6, 255]))
    add('builtin_tab_index', "return {'select-tab-2_5_5'}", bytes([1, 7, 254]))
    add('builtin_workspace_index', "return {'select-workspace-255'}", bytes([1, 17, 254]))
    add('context_zero', 'assert(not ctx.sidebar_visible and ctx.tab_count==0 and ctx.active_tab_index==1 and ctx.pane_count==0 and ctx.focused_pane_id==0); return {}', bytes([0]), context=['0'] * 5)
    add('context_upper_counts', 'assert(ctx.tab_count==65535 and ctx.active_tab_index==65536 and ctx.pane_count==65535); return {}', bytes([0]), context=['0', '65_535', '65535', '65535', '0'])
    add('partial_batch_rejected', "return {t.action.toggle_sidebar(),t.action.scroll_pane{direction='up'}}", None)
    add('oversized_command_dropped', "local args={};for i=1,33 do args[i]='x' end;return {t.action.command_tab{command=args},t.action.toggle_sidebar()}", bytes([1, 3]))
    add('oversized_command_bytes_dropped', "return t.action.command_tab{command={string.rep('x',4097)}}", bytes([0]))
    add('unsupported_valid_command', "return t.action.command_tab{command={'echo','hello'}}", None)
    add('unknown_field', "return {kind='toggle-sidebar',unexpected=true}", None)
    add('unknown_builtin', "return {'focus-outside'}", None)
    add('single_string_rejected', "return 'toggle-sidebar'", None)
    add('missing_module', "require('config.missing'); return {}", None)
    add('module_traversal', "require('../outside'); return {}", None)
    add('module_cycle', "require('config.cycle'); return {}", None, files={'config/cycle.lua': "return require('config.cycle')"})
    add('module_cache', "local a=require('config.once'); assert(a==require('config.once')); return {}", bytes([0]), files={'config/once.lua': 'return {}'})
    add('top_level_loop', 'return {}', None)
    cases[-1]['source'] = 'while true do end'
    default_notification = bytes([1, 18, 0]) + struct.pack('<I', 4000) + bytes([0])
    add('notification_defaults', "return t.action.notification{title='x'}", default_notification + struct.pack('<H', 1) + b'x' + struct.pack('<H', 0))
    add('notification_utf8_truncation', "return t.action.notification{title=string.rep('漢',33),body=string.rep('漢',171)}", default_notification + struct.pack('<H', 96) + ('漢' * 32).encode() + struct.pack('<H', 510) + ('漢' * 170).encode())
    for name, fields in (
            ('empty_title', "title=''"),
            ('nul_title', "title=string.char(0)"),
            ('invalid_utf8', "title=string.char(255)"),
            ('zero_target', "title='x',pane_id=0"),
            ('short_duration', "title='x',duration_ms=499"),
            ('long_duration', "title='x',duration_ms=60001"),
            ('invalid_level', "title='x',level='unknown'")):
        add('notification_' + name, f'return t.action.notification{{{fields}}}', None)
    add('invalid_action_name', 'return {}', None, action='run\"')
    cases.extend([
        dict(name='punctuated_action_name', source="local t=require('telar'); return {actions={[\"run.with-dash\"]=function()return t.action.toggle_sidebar()end}}", action='run.with-dash', expected=bytes([1, 3])),
        dict(name='lexical_telar', source='_G.telar=nil; return {actions={run=function()return telar.action.toggle_sidebar()end}}', expected=bytes([1, 3])),
        dict(name='replaced_binder', source="telar.bind_global=function(keys,callback)return {keys=keys,action=function()return telar.action.new_tab()end,prefixed=false,expression=false}end;return {actions={run=function()return {}end}}", expected=bytes([1, 5])),
        dict(name='invalid_binder', source='telar.bind_global=nil;return {actions={run=function()return {}end}}', expected=None),
        dict(name='replaced_type', source='type=nil; return {actions={run=function()return {}end}}', expected=None),
        dict(name='missing_actions', source='return {}', expected=None),
        dict(name='nonfunction_action', source='return {actions={run=1}}', expected=None),
        dict(name='syntax_error', source='return {', expected=None),
        dict(name='source_limit', source='--' + 'x' * (1024 * 1024), expected=None),
    ])
    return cases


def invoke(binary, entry, context, action):
    command = [str(binary), 'plugin-worker', str(entry), action, *context]
    try:
        result = subprocess.run(command, cwd='/', env={}, capture_output=True, timeout=5)
    except subprocess.TimeoutExpired as error:
        return dict(command=command, timeout=True, stdout_hex=(error.stdout or b'').hex(), stderr=(error.stderr or b'').decode(errors='replace'))
    return dict(command=command, timeout=False, exit_code=result.returncode,
                stdout_hex=result.stdout.hex(), stderr=result.stderr.decode(errors='replace'))


def matches(result, expected):
    if result['timeout']:
        return False
    if expected is None:
        return result['exit_code'] > 0 and not result['stdout_hex']
    return result['exit_code'] == 0 and result['stdout_hex'] == expected.hex()


def main():
    with contextlib.ExitStack() as cleanup:
        return run(cleanup)


def run(cleanup):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', type=Path, help='Optional original-Zig reference executable')
    parser.add_argument('--cpp', type=Path, required=True)
    parser.add_argument('--output', type=Path, help='New receipt directory; defaults to a temporary directory')
    args = parser.parse_args()
    binaries = {name: path.resolve(strict=True) for name, path in (('zig', args.zig), ('cpp', args.cpp)) if path is not None}
    if args.output is None:
        args.output = Path(cleanup.enter_context(tempfile.TemporaryDirectory(prefix='telar-action-worker-'))) / 'receipts'
    output = args.output.resolve()
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    report = dict(scope='One-shot worker exit status and exact effect bytes; no performance claim',
                  binaries={name: dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest()) for name, path in binaries.items()}, cases=[])
    for case in fixtures():
        directory = output / case['name']
        directory.mkdir(mode=0o700)
        entry = directory / 'main.lua'
        entry.write_text(case['source'])
        for name, source in case.get('files', {}).items():
            module = directory / name
            module.parent.mkdir(parents=True, exist_ok=True)
            module.write_text(source)
        row = dict(name=case['name'], expected_hex=case['expected'].hex() if case['expected'] is not None else None)
        for name, binary in binaries.items():
            row[name] = invoke(binary, entry, case.get('context', ['1', '3', '1', '2', '42']), case.get('action', 'run'))
            row[name]['matches_expected'] = matches(row[name], case['expected'])
        row['passed'] = all(row[name]['matches_expected'] for name in binaries)
        report['cases'].append(row)
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(case['name'], 'passed' if row['passed'] else 'FAILED', flush=True)
    report['passed'] = all(row['passed'] for row in report['cases'])
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
