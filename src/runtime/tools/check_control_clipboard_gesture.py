#!/usr/bin/env python3
"""Private offscreen Qt gesture through Controller's binding, runtime and PTY."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from bench_control_pty import stop_owned_process


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    runtime, probe = args.runtime.resolve(), args.probe.resolve()
    with tempfile.TemporaryDirectory(prefix='telar-clipboard-gesture-', dir='/tmp') as directory:
        root = Path(directory)
        socket = root / 'runtime.sock'
        environment = {k: v for k, v in os.environ.items() if not k.startswith(('TELAR_', 'XDG_', 'QT_'))}
        for key in ['HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR']:
            location = root / key.lower()
            location.mkdir()
            environment[key] = str(location)
        environment.update(QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software')
        command = [str(runtime), '--socket', str(socket), '--history', ':memory:', '--no-session', '--no-config']
        with (root / 'runtime.log').open('w+') as log:
            server = subprocess.Popen(command, env=environment, cwd=root, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                while not socket.exists():
                    if server.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError('Owned runtime did not start')
                    time.sleep(.01)
                report_path = root / 'gesture.json'
                completed = subprocess.run([str(probe), str(socket), str(report_path)], env=environment,
                                           cwd=root, capture_output=True, text=True, timeout=60)
                log.flush()
                log.seek(0)
                runtime_log = log.read()
                if completed.returncode:
                    raise RuntimeError(f'Gesture probe exit{completed.returncode}: {completed.stdout}; {completed.stderr}; runtime_log={runtime_log}')
                parent = json.loads(report_path.read_text())
                child = json.loads(Path(str(report_path) + '.child').read_text())
                if parent['real_gestures'] != 2 or parent['listing_text_reads'] != 0 or parent['total_text_reads'] != 2 or not all(child.values()):
                    raise RuntimeError('Incomplete gesture assertions')
                if runtime_log:
                    raise RuntimeError('Unexpected owned runtime diagnostics: ' + runtime_log)
                result = {'parent': parent, 'child': child, 'probe_stderr': completed.stderr, 'runtime_log': runtime_log,
                          'command': command, 'hashes': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [runtime, probe, Path(__file__)]},
                          'scope': 'Real platform Paste key event → TerminalItem → exact binding called by Controller → RuntimeConnection with actual handshake/attach → runtime → PTY. Targets listing, password-authorized Qt read, and ordinary bracketed paste are byte-exact in the PTY child.',
                          'limits': ['The complete Controller/native window lifecycle is not instantiated; its production paste binding is shared, not copied in the fixture.',
                                     'Offscreen Qt owns only test MIME data; a platform assertion precedes all QClipboard access. No host clipboard is read or modified.',
                                     'Private executable paths are supplied; no installation or other runtime/session changes.']}
            finally:
                stop_owned_process(server)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'passed': True, 'gestures': 2}))


if __name__ == '__main__':
    main()
