import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from capture_fullscreen_strip import replace_once, repository, sha


attention_setup = r'''
def configure_attention(fixture):
    import subprocess
    binary = os.environ['TELAR_BIN_PATH']
    socket = os.environ['TELAR_SOCKET_PATH']
    pane = int(os.environ['TELAR_PANE_ID'])
    timeout_seconds = 20
    poll_seconds = .05
    deadline = time.monotonic() + timeout_seconds
    while not (fixture.directory / 'attention.ready').is_file():
        if time.monotonic() >= deadline:
            raise TimeoutError('Native setup did not release attention reporting')
        time.sleep(poll_seconds)

    def cli(*arguments, payload=None):
        result = subprocess.run([binary, *arguments, '--socket', socket], input=json.dumps(payload) if payload is not None else None, capture_output=True, text=True, timeout=timeout_seconds)
        if result.returncode:
            raise RuntimeError(str(arguments) + ': ' + result.stderr)
        return result.stdout

    def current():
        snapshot = json.loads(cli('agent', 'list', '--json'))
        return next((agent for agent in snapshot['agents'] if agent['pane_id'] == pane), None)

    def await_agent(predicate):
        deadline = time.monotonic() + timeout_seconds
        agent = None
        while time.monotonic() < deadline:
            agent = current()
            if agent is not None and predicate(agent):
                return agent
            time.sleep(poll_seconds)
        raise RuntimeError('Attention fixture did not stabilize: ' + json.dumps(agent))

    cli('hook', 'claude', payload=dict(hook_event_name='SessionStart', cwd=os.getcwd(), session_id='parity-attention-' + str(pane), session_title='Attention fixture'))
    await_agent(lambda agent: agent['provider'] == 'claude')
    cli('agent', 'report-state', '--current', 'blocked', '--blocked-reason', 'question', '--event', 'Choose a schema')
    agent = await_agent(lambda agent: agent['status'] == 'blocked')
    atomic_json(fixture.directory / ('attention-' + str(pane) + '.json'), agent)

'''


def attention_probe(source):
    source = replace_once(source, 'static void setup_tick(void) {', r'''static BOOL attention_ready(void) {
    NSString *gate = [display_directory stringByAppendingPathComponent:@"attention.ready"];
    [[NSData data] writeToFile:gate atomically:YES];
    unsigned count = 0;
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:display_directory error:nil]) {
        if (![name hasPrefix:@"attention-"] || ![name hasSuffix:@".json"]) continue;
        NSData *data = [NSData dataWithContentsOfFile:[display_directory stringByAppendingPathComponent:name]];
        NSDictionary *agent = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![agent[@"status"] isEqual:@"blocked"]) return NO;
        count++;
    }
    return count == panes;
}

static void setup_tick(void) {''')
    return replace_once(source, 'if (setup_stage == ProbeSetupForeground && prepare_foreground()) {', 'if (setup_stage == ProbeSetupForeground && attention_ready() && prepare_foreground()) {')


def main():
    parser = argparse.ArgumentParser(description='Capture unfocused blocked panes through the original runtime and both native GUIs')
    parser.add_argument('zig_binary', type=Path)
    parser.add_argument('output_directory', type=Path)
    options, arguments = parser.parse_known_args()
    output = options.output_directory.resolve()
    if output.exists():
        parser.error('The output directory must be new')
    names = sorted(path.name for path in (repository / 'tools').iterdir() if path.is_file() and path.suffix in {'.py', '.m', '.h'})
    originals = {name: sha(repository / 'tools' / name) for name in names}
    with tempfile.TemporaryDirectory(prefix='telar-attention-probe-') as directory:
        source = Path(directory)
        for name in names:
            shutil.copy2(repository / 'tools' / name, source / name)
        launcher = source / 'foreground_fixture.py'
        shutil.copy2(Path(__file__).with_name(launcher.name), launcher)
        interpreter = source / 'claude'
        shutil.copy2(sys.executable, interpreter)
        runner = source / 'gui_tui_latency.py'
        runner.write_text(replace_once(runner.read_text(), "    if mode == 'gui':\n", "    fixture[0] = str(Path(__file__).with_name('claude'))\n    fixture = [sys.executable, str(Path(__file__).with_name('foreground_fixture.py')), *fixture]\n    if mode == 'gui':\n"))
        runner.write_text(replace_once(runner.read_text(), 'import time\n', 'import time\nimport sys\n'))
        fixture = source / 'terminal_bench_fixture.py'
        fixture.write_text(replace_once(fixture.read_text(), 'class Fixture:\n', attention_setup + '\nclass Fixture:\n'))
        fixture.write_text(replace_once(fixture.read_text(), '    def record(self):\n', '        import threading\n        with defer_resize():\n            threading.Thread(target=configure_attention, args=(self,), daemon=True).start()\n\n    def record(self):\n'))
        fixture.write_text(replace_once(fixture.read_text(), 'dict(pid=self.pid, ppid=os.getppid(),', 'dict(pid=self.pid, ppid=os.getppid(), process_group=os.getpgrp(), foreground_group=os.tcgetpgrp(0),'))
        probe = source / 'gui_tui_latency.m'
        probe.write_text(attention_probe(probe.read_text()))
        command = [sys.executable, str(source / 'gui_tui_latency.py'), str(options.zig_binary.resolve()), str(output), *arguments, '--mode', 'telar', '--cases', 'splits', '--capture', '--source', str(repository)]
        try:
            subprocess.run(command, check=True)
            for path in output.glob('*-splits-*/receipts/*.json'):
                receipt = json.loads(path.read_text())
                if receipt['pid'] != receipt['process_group'] or receipt['foreground_group'] != receipt['process_group'] or receipt['ppid'] == receipt['process_group']:
                    raise RuntimeError('The agent fixture must own its foreground group')
                agents = list(path.parent.parent.glob('attention-*.json'))
                if not agents or any(json.loads(agent.read_text())['status'] != 'blocked' for agent in agents):
                    raise RuntimeError('Every fixture must reach the blocked state')
        finally:
            if output.is_dir():
                saved = output / 'attention-probe-source'
                saved.mkdir(exist_ok=False)
                for name in [*names, launcher.name]:
                    shutil.copy2(source / name, saved / name)
                metadata = dict(adapter_sha256=sha(Path(__file__)), source_sha256=originals, derived_sha256={name: sha(source / name) for name in [*names, launcher.name]}, interpreter_sha256=sha(interpreter), command_line=command, scope='Each foreground fixture uses a copied Python interpreter named claude so the unmodified runtime observes it as an agent. A file barrier releases real SessionStart and report-state commands after native split/focus setup. Capture waits for every blocked/question receipt. The common probe retains its geometry, native focus, marker and GPU-completion checks. Timing samples remain diagnostic.')
                (output / 'pane-attention-probe.json').write_text(json.dumps(metadata, indent=2) + '\n')


if __name__ == '__main__':
    main()
