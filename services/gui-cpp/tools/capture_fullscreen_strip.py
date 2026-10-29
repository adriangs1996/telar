import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


repository = Path(__file__).resolve().parents[3]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise RuntimeError('The common probe changed; review the fullscreen setup adapter')
    return source.replace(before, after)


def fullscreen_probe(source):
    source = replace_once(source, '        if (setup_stage == ProbeSetupForeground && prepare_foreground()) {', r'''        static BOOL fullscreen_requested = NO;
        const double fullscreen_settle_seconds = .5;
        if (setup_stage == ProbeSetupForeground && !fullscreen_requested) {
            if (!inject_key(primary_view, (ProbeKey){ @"\002", @"b", NSEventModifierFlagControl, 11 }) ||
                !inject_key(primary_view, (ProbeKey){ @"z", @"z", 0, 6 })) { finish(8); return; }
            fullscreen_requested = YES;
            setup_changed = now;
        }
        if (setup_stage == ProbeSetupForeground && now - setup_changed >= fullscreen_settle_seconds && prepare_foreground()) {''')
    return replace_once(source, r'''    if (!inject_key(view, (ProbeKey){ @"\002", @"b", NSEventModifierFlagControl, 11 })) return NO;
    if (create && tabs)''', r'''    const unsigned balanced_four_pane_threshold = 800;
    if (create && !tabs && panes == 4 && requested_width < balanced_four_pane_threshold && (created_panes == 2 || created_panes == 3)) {
        if (!inject_key(view, (ProbeKey){ @"\002", @"b", NSEventModifierFlagControl, 11 })) return NO;
        unichar direction = created_panes == 2 ? NSLeftArrowFunctionKey : NSRightArrowFunctionKey;
        NSString *arrow = [NSString stringWithFormat:@"%C", direction];
        if (!inject_key(view, (ProbeKey){ arrow, arrow, 0, created_panes == 2 ? 123 : 124 })) return NO;
    }
    if (!inject_key(view, (ProbeKey){ @"\002", @"b", NSEventModifierFlagControl, 11 })) return NO;
    if (create && tabs)''')


def main():
    parser = argparse.ArgumentParser(description='Capture both GUIs after entering pane fullscreen with the same native bindings')
    parser.add_argument('zig_binary', type=Path)
    parser.add_argument('output_directory', type=Path)
    parser.add_argument('--with-progress', action='store_true')
    options, arguments = parser.parse_known_args()
    output = options.output_directory.resolve()
    if output.exists():
        parser.error('The output directory must be new')
    names = sorted(path.name for path in (repository/'tools').iterdir() if path.is_file() and path.suffix in {'.py', '.m', '.h'})
    originals = {name:sha(repository/'tools'/name) for name in names}
    with tempfile.TemporaryDirectory(prefix='telar-fullscreen-probe-') as directory:
        source = Path(directory)
        for name in names:
            shutil.copy2(repository/'tools'/name, source/name)
        launcher = source/'foreground_fixture.py'
        shutil.copy2(Path(__file__).with_name(launcher.name), launcher)
        runner = source/'gui_tui_latency.py'
        runner.write_text(replace_once(runner.read_text(), "    if mode == 'gui':\n", "    fixture = [sys.executable, str(Path(__file__).with_name('foreground_fixture.py')), *fixture]\n    if mode == 'gui':\n"))
        runner.write_text(replace_once(runner.read_text(), 'import time\n', 'import time\nimport sys\n'))
        probe = source/'gui_tui_latency.m'
        probe.write_text(fullscreen_probe(probe.read_text()))
        if options.with_progress:
            fixture = source/'terminal_bench_fixture.py'
            fixture.write_text(replace_once(fixture.read_text(), '    def draw_marker(self):\n', "    def draw_marker(self):\n        write_all(b'\\x1b]9;4;1;70\\x07')\n"))
        fixture = source/'terminal_bench_fixture.py'
        fixture.write_text(replace_once(fixture.read_text(), 'dict(pid=self.pid, ppid=os.getppid(),', 'dict(pid=self.pid, ppid=os.getppid(), process_group=os.getpgrp(), foreground_group=os.tcgetpgrp(0),'))
        command = [sys.executable, str(source/'gui_tui_latency.py'), str(options.zig_binary.resolve()), str(output), *arguments, '--mode', 'telar', '--cases', 'splits', '--capture', '--source', str(repository)]
        try:
            subprocess.run(command, check=True)
            for path in output.glob('*-splits-*/receipts/*.json'):
                receipt = json.loads(path.read_text())
                if receipt['pid'] != receipt['process_group'] or receipt['foreground_group'] != receipt['process_group'] or receipt['ppid'] == receipt['process_group']:
                    raise RuntimeError('The terminal fixture must own a foreground group distinct from its pane root')
        finally:
            if output.is_dir():
                saved = output/'fullscreen-probe-source'
                saved.mkdir(exist_ok=False)
                for name in [*names, launcher.name]:
                    shutil.copy2(source/name, saved/name)
                metadata = dict(adapter_sha256=sha(Path(__file__)), source_sha256=originals, derived_sha256={name:sha(source/name) for name in [*names, launcher.name]}, command_line=command, progress_requested=options.with_progress, scope='The common probe retains its viewport, grid, marker, foreground and GPU-completion checks. Setup adds Ctrl+B,z after returning to the primary pane. Narrow four-pane scenes balance splits through the same native focus bindings. Each fixture runs in its own foreground process group, distinct from the pane root, so optional OSC 9;4;1;70 has foreground-job ownership. Receipts verify those groups. Timing samples remain diagnostic.')
                (output/'fullscreen-strip-probe.json').write_text(json.dumps(metadata,indent=2)+'\n')


if __name__ == '__main__':
    main()
