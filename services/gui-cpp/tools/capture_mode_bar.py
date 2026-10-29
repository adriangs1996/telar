import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import capture_provider_marks


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def mode_probe(source, mode):
    enter = 'if (!inject_key(primary_view, (ProbeKey){ @"r", @"r", 0, 15 }))'
    prefix = 'if (!inject_key(primary_view, (ProbeKey){ @"b", @"b", NSEventModifierFlagControl, 11 }))'
    if source.count(enter) != 1:
        raise RuntimeError('The original capture key injection was not found uniquely')
    source = source.replace(enter, prefix)
    if mode == 'copy':
        anchor = '''            }
            observe_idle_cpu();'''
        replacement = '''                if (!inject_key(primary_view, (ProbeKey){ @"[", @"[", 0, 33 })) {
                    finish(8);
                    return;
                }
            }
            observe_idle_cpu();'''
        if source.count(anchor) != 1:
            raise RuntimeError('The original capture setup boundary was not found uniquely')
        source = source.replace(anchor, replacement)
        source = source.replace('                atomic_store(&capture_requested, true);', '', 1)
        arm = '''            }
            observe_idle_cpu();'''
        delayed = '''                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    atomic_store(&capture_requested, true);
                    [primary_view setNeedsDisplay:YES];
                });
            }
            observe_idle_cpu();'''
        if source.count(arm) != 1:
            raise RuntimeError('The copy capture boundary was not found uniquely')
        source = source.replace(arm, delayed)
    capture_check = '''        if (capture_path && !capture_complete) {
            finish(ProbeFailureCapture);
            return;
        }
'''
    if source.count(capture_check) != 1:
        raise RuntimeError('The original idle capture check was not found uniquely')
    source = source.replace('        send_key();\n    });\n}', '        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ send_key(); });\n    });\n}', 1)
    return source.replace(capture_check, capture_check + '''        if (capture_path) {
            NSWindow *window = primary_view.window;
            if (!window) {
                finish(8);
                return;
            }
            NSEvent *escape = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil
                characters:@"\\033" charactersIgnoringModifiers:@"\\033" isARepeat:NO keyCode:53];
            [NSApp postEvent:escape atStart:NO];
        }
''')


def main():
    parser = argparse.ArgumentParser(description='Capture original and C++ prefix/copy footers with the existing isolated Metal probe')
    parser.add_argument('mode', choices=['prefix', 'copy'])
    parser.add_argument('zig_binary', type=Path)
    parser.add_argument('output_directory', type=Path)
    options, arguments = parser.parse_known_args()
    output = options.output_directory.resolve()
    original = capture_provider_marks.repository / 'tools/gui_tui_latency.m'
    original_run = subprocess.run
    compilations = 0
    with tempfile.TemporaryDirectory(prefix='telar-mode-probe-') as temporary:
        adapted = Path(temporary) / original.name
        adapted.write_text(mode_probe(original.read_text(), options.mode))

        def run(command, *args, **kwargs):
            nonlocal compilations
            if isinstance(command, list) and command and command[0] == 'clang' and str(original) in command:
                command = [str(adapted) if value == str(original) else value for value in command]
                command[1:1] = ['-I', str(original.parent)]
                compilations += 1
            return original_run(command, *args, **kwargs)

        saved_arguments = sys.argv
        subprocess.run = run
        sys.argv = [str(Path(capture_provider_marks.__file__)), 'codex', str(options.zig_binary), str(output), *arguments]
        try:
            capture_provider_marks.main()
        finally:
            subprocess.run = original_run
            sys.argv = saved_arguments
            if output.exists():
                record = {
                    'mode': options.mode, 'synthetic_workload': True, 'probe_compilations': compilations,
                    'original_probe': str(original), 'original_probe_sha256': sha(original), 'adapted_probe_sha256': sha(adapted),
                    'adaptation': 'The existing capture-trigger key enters prefix or copy mode. An AppKit-queued Escape restores normal mode after idle capture. A 200 ms delay lets the native event queue process Escape before input measurement. Copy capture waits 200 ms before arming readback so the intermediate prefix frame is not captured. Frame readback and marker/grid validation are unchanged.',
                    'scope': 'Visual diagnostics only. This modified input sequence is not accepted performance evidence.',
                }
                (output / 'mode-capture-probe.json').write_text(json.dumps(record, indent=2) + '\n')
                (output / 'mode-capture-probe.m').write_bytes(adapted.read_bytes())
    if compilations != 1:
        raise RuntimeError('The capture did not compile exactly one adapted probe')


if __name__ == '__main__':
    main()
