#!/usr/bin/env python3
"""Real socket EOF/reconnect and clipboard completion through an owned runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from bench_control_pty import stop_owned_process


def run(runtime, probe, stage):
    with tempfile.TemporaryDirectory(prefix='telar-clipboard-lifetime-', dir='/tmp') as directory:
        root = Path(directory)
        socket = root / 'runtime.sock'
        environment = {k: v for k, v in os.environ.items() if not k.startswith(('TELAR_', 'XDG_'))}
        for key in ['HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR']:
            location = root / key.lower()
            location.mkdir()
            environment[key] = str(location)
        command = [str(runtime), '--socket', str(socket), '--history', ':memory:', '--no-session', '--no-config']
        with (root / 'runtime.log').open('w+') as log:
            server = subprocess.Popen(command, env=environment, cwd=root, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                while not socket.exists():
                    if server.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError('Owned runtime did not start')
                    time.sleep(.01)
                child_report = root / 'child.json'
                result = subprocess.run([str(probe), str(socket), str(child_report), stage], env=environment,
                                        cwd=root, capture_output=True, text=True, timeout=30)
                log.flush()
                log.seek(0)
                runtime_log = log.read()
                if result.returncode:
                    raise RuntimeError(f'{stage}: probe exit{result.returncode}; {result.stdout}; {result.stderr}; runtime_log={runtime_log}')
                measured = {'parent': json.loads(result.stdout), 'child': json.loads(child_report.read_text()),
                            'runtime_log': runtime_log, 'command': command}
                if not all(measured['child'].values()) or measured['parent']['fresh_provider_writes'] != 1:
                    raise RuntimeError('Incomplete clipboard lifetime assertions')
                if runtime_log:
                    raise RuntimeError('Unexpected owned runtime diagnostics: ' + runtime_log)
                return measured
            finally:
                stop_owned_process(server)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    runtime, probe = args.runtime.resolve(), args.probe.resolve()
    reports = [run(runtime, probe, stage) for stage in ['requested', 'committed']]
    report = {'reports': reports, 'hashes': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [runtime, probe, Path(__file__)]},
              'scope': 'Actual EOF reaches Runtime.dropClient; same pane survives reconnect; stale old-client tickets and duplicate fresh completion cannot authorize another provider effect. Provider is entirely in memory.',
              'limits': ['Committed old operation executes before disconnect; effects already performed are counted and cannot be undone.',
                         'Does not instantiate the Qt consumer or simulate reuse of a pane ID. No host clipboard access.',
                         'Runtime and driver are supplied explicitly; this tool neither installs nor restarts another runtime.']}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'stages': len(reports), 'all_passed': True}))


if __name__ == '__main__':
    main()
