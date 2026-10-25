#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time

from check_history_availability import fingerprint


def check(binary, probe, root, submit):
    endpoint = root / 'runtime.sock'
    endpoint.unlink(missing_ok=True)
    database = root / 'history.db'
    environment = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    for name in ('HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME'):
        directory = root / name.lower()
        directory.mkdir(exist_ok=True)
        environment[name] = str(directory)
    environment.update(SHELL='/bin/sh', TERM='xterm-256color')
    configuration = root / 'runtime.lua'
    configuration.write_text('return {api_version=2,runtime={history={path=' + json.dumps(str(database)) + '},proxy={enabled=false},session={persist=false}}}\n')
    dump = root / 'history.bin'
    with (root / 'server.log').open('w+') as log:
        server = subprocess.Popen([str(binary), 'server', '--socket', str(endpoint), '--config', str(configuration)], env=environment, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 20
            while not endpoint.exists():
                if server.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('Runtime did not start')
                time.sleep(0.01)
            if submit:
                with sqlite3.connect(database, timeout=5) as lock:
                    lock.execute('BEGIN IMMEDIATE')
                    subprocess.run([str(probe), str(endpoint), 'history-disconnect', '1', str(dump)], env=environment, check=True, capture_output=True, timeout=10)
                    lock.rollback()
            subprocess.run([str(probe), str(endpoint), 'history-retained', '1', str(dump)], env=environment, check=True, capture_output=True, timeout=10)
            return hashlib.sha256(dump.read_bytes()).hexdigest()
        except Exception as error:
            log.flush()
            log.seek(0)
            details = error.stderr.decode(errors='replace') if isinstance(error, subprocess.CalledProcessError) else ''
            raise RuntimeError(f'{error}\n{details}\n{log.read()}') from error
        finally:
            if server.poll() is None:
                server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
            log.flush()
            log.seek(0)
            diagnostics = log.read()
            if server.returncode not in (0, -15) or 'ERROR: AddressSanitizer' in diagnostics or 'runtime error:' in diagnostics:
                raise RuntimeError(f'Runtime shutdown failed ({server.returncode})\n{diagnostics}')


def main():
    parser = argparse.ArgumentParser(description='Hold SQLite writes while an accepted import loses its client')
    for name in ('zig', 'cpp', 'probe', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    arguments = parser.parse_args()
    binaries = {name: getattr(arguments, name).resolve() for name in ('zig', 'cpp', 'probe')}
    report = {'binaries': {name: fingerprint(binary) for name, binary in binaries.items()}, 'cases': {}}
    for language in ('zig', 'cpp'):
        try:
            with tempfile.TemporaryDirectory(prefix='telar-history-disconnect-', dir='/tmp') as temporary:
                root = Path(temporary)
                disconnected = check(binaries[language], binaries['probe'], root, True)
                restarted = check(binaries[language], binaries['probe'], root, False)
                assert disconnected == restarted, 'Persisted imports changed after restart'
                report['cases'][language] = {'passed': True, 'sha256': disconnected}
        except Exception as error:
            report['cases'][language] = {'passed': False, 'error': str(error)}
    report['passed'] = all(case['passed'] for case in report['cases'].values()) and report['cases']['zig'] == report['cases']['cpp']
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['cases'], indent=2))
    return int(not report['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
