#!/usr/bin/env python3
"""Reproduce macOS early-disconnect failure and verify an isolated runtime fix.

Only runtimes started by this tool are paused, and their executable identities are
verified through a live protocol connection. This is a functional regression, not
a performance measurement. The baseline must exhibit the known SIGPIPE-option
failure; the candidate must keep serving healthy requests after every batch.
"""

from pathlib import Path
import argparse
import hashlib
import json
import shlex
import shutil
import os
import signal
import socket
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(root / 'tools'))
from perf_e2e import isolated_environment, stop_runtime
from bench_stack import process_identity, executable_identity

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build', type=Path, required=True)
parser.add_argument('--before', type=Path, required=True)
parser.add_argument('--after', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(mode=0o700, exist_ok=False)
source = output / 'disconnected_clients_probe.cpp'
shutil.copy2(Path(__file__).with_name(source.name), source)
shutil.copy2(__file__, output / Path(__file__).name)
build = args.build.resolve()
entries = json.loads((build / 'compile_commands.json').read_text())
entry = next(row for row in entries if Path(row['file']).name == 'history_test.cpp')
command = shlex.split(entry['command'])
command.remove('-c')
probe = output / 'disconnected-clients-probe'
command[command.index('-o') + 1] = str(probe)
command = [str(source) if word == entry['file'] else word for word in command]
command.append(str(build / 'telar-platform/libtelar-platform.a'))
with (output / 'build.log').open('w') as log:
    subprocess.run(command, cwd=entry['directory'], stdout=log, stderr=subprocess.STDOUT, check=True)
variants = {'A': args.before.resolve(strict=True), 'B': args.after.resolve(strict=True)}
manifest = dict(scope=__doc__, compile=command, probe=executable_identity(probe),
                source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                runtimes={label: executable_identity(binary) for label, binary in variants.items()})
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
reports = {}
for label, runtime in variants.items():
    directory = output / label
    env = isolated_environment(directory)
    env['TELAR_HISTORY'] = str(directory / 'history.db')
    for name in ('DYLD_INSERT_LIBRARIES', 'DYLD_LIBRARY_PATH', 'DYLD_FRAMEWORK_PATH'):
        env.pop(name, None)
    child = None
    paused = False
    pid = None
    rounds = 10
    with (directory / 'probe.log').open('w') as log:
        try:
            start = subprocess.run([str(runtime), 'server', '--background', '--no-config', '--no-session'], env=env, cwd=directory, capture_output=True, text=True, timeout=15)
            (directory / 'start.log').write_text(start.stdout + start.stderr)
            start.check_returncode()
            child = subprocess.Popen([str(probe), env['TELAR_SOCKET_PATH'], str(directory), str(rounds)], env=env, cwd=directory, stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 15
            while not (directory / 'ready').exists():
                if child.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('Health probe failed to connect')
                time.sleep(.01)
            pid = int((directory / 'ready').read_text())
            identity = process_identity(pid)
            assert identity['path'] == str(runtime.resolve()) and identity['sha256'] == executable_identity(runtime)['sha256']
            (directory / 'runtime-identity.json').write_text(json.dumps(identity, indent=2) + '\n')
            completed = 0
            for index in range(rounds):
                assert process_identity(pid) == identity
                os.kill(pid, signal.SIGSTOP)
                paused = True
                for _ in range(8):
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as abandoned:
                        abandoned.settimeout(3)
                        abandoned.connect(env['TELAR_SOCKET_PATH'])
                os.kill(pid, signal.SIGCONT)
                paused = False
                (directory / f'release-{index}').write_text('release\n')
                deadline = time.monotonic() + 15
                while not (directory / f'done-{index}').exists():
                    if child.poll() is not None:
                        break
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Runtime stopped responding after abandoned connections')
                    time.sleep(.01)
                if not (directory / f'done-{index}').exists():
                    break
                completed += 1
                time.sleep(.03)
            code = child.wait(timeout=15)
            runtime_log = Path(env['TELAR_SOCKET_PATH'] + '.runtime.start.log').read_text()
            reports[label] = dict(completed_rounds=completed, abandoned_per_round=8, health_requests_per_round=2, probe_exit_code=code, runtime_log=runtime_log)
            if label == 'A':
                assert code != 0 and 'Disable socket SIGPIPE: Invalid argument' in runtime_log
            else:
                assert code == 0 and completed == rounds and not runtime_log
        finally:
            if paused:
                os.kill(pid, signal.SIGCONT)
            if child is not None and child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
            cleanup = stop_runtime(runtime, env)
            (directory / 'cleanup.json').write_text(json.dumps(cleanup, indent=2) + '\n')
            assert all(cleanup[key] for key in ('cleanup_complete', 'children_exited', 'exited'))
    print(label, reports[label], flush=True)
(output / 'result.json').write_text(json.dumps(dict(passed=True, performance_eligible=False, variants=reports), indent=2) + '\n')
