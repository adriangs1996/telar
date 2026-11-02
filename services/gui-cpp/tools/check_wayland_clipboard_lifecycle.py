"""Test raw Wayland clipboard lifecycle on owned servers, without a GUI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import subprocess

from check_wayland_clipboard import stop


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args()
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    server_binary, probe_binary = options.server.resolve(), options.probe.resolve()
    record = dict(scope='Raw owned Wayland protocol components; no compositor, GUI or user display', binaries={str(path): sha(path) for path in (server_binary, probe_binary)}, sanitizers={name: os.environ.get(name) for name in ('ASAN_OPTIONS', 'UBSAN_OPTIONS', 'LSAN_OPTIONS', 'ASAN_SYMBOLIZER_PATH', 'LD_LIBRARY_PATH')}, cases=[])
    variants = [('modern', 8, 3, False), ('legacy', 1, 1, False), ('legacy-seat', 1, 3, False), ('legacy-manager', 8, 1, False), ('late-seat', 8, 3, True)]
    for index, (name, seat_version, manager_version, late) in enumerate(variants):
        case = output / name
        case.mkdir()
        runtime = output / 'r' / str(index)
        runtime.mkdir(parents=True, mode=0o700)
        environment = dict(os.environ, XDG_RUNTIME_DIR=str(runtime))
        environment.pop('WAYLAND_DISPLAY', None)
        environment.pop('DISPLAY', None)
        if late:
            environment['TELAR_WAYLAND_TEST_LATE_SEAT'] = '1'
        else:
            environment.pop('TELAR_WAYLAND_TEST_LATE_SEAT', None)
        server_end, probe_end = socket.socketpair()
        command = [str(server_binary), str(seat_version), str(manager_version)]
        with (case / 'server.log').open('wb') as log:
            server = subprocess.Popen(command, stdin=server_end, stdout=subprocess.PIPE, stderr=log, env=environment)
        server_end.close()
        entry = dict(name=name, server_command=command, owned_server_pid=server.pid)
        record['cases'].append(entry)
        try:
            assert select.select([server.stdout], [], [], 5)[0], 'Owned server readiness timeout'
            display = server.stdout.readline().decode().strip()
            assert display.startswith('wayland-'), display
            environment['WAYLAND_DISPLAY'] = display
            arguments = [str(probe_binary), str(case / 'observation.json')]
            if late:
                arguments.append('late')
            with (case / 'probe.log').open('wb') as log:
                probe = subprocess.Popen(arguments, stdin=probe_end, stdout=log, stderr=subprocess.STDOUT, env=environment)
                probe_end.close()
                entry['owned_probe_pid'] = probe.pid
                try:
                    entry['actual_probe_exit'] = probe.wait(timeout=20)
                except BaseException:
                    stop(probe)
                    raise
            entry['observation'] = json.loads((case / 'observation.json').read_text())
            entry['passed'] = entry['actual_probe_exit'] == 0 and entry['observation']['failed'] == 0 and len(entry['observation']['cases']) == (13 if late else 12)
            print(name, len(entry['observation']['cases']), 'passed' if entry['passed'] else 'FAILED', 'actual exit', entry['actual_probe_exit'], flush=True)
        finally:
            probe_end.close()
            try:
                entry['server_cleanup_exit'] = server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                stop(server)
                entry['server_cleanup_exit'] = server.returncode
            server.stdout.close()
            (output / 'results.json').write_text(json.dumps(record, indent=2) + '\n')
        entry['passed'] = entry['passed'] and entry['server_cleanup_exit'] == 0
    assert all(sha(Path(path)) == identity for path, identity in record['binaries'].items())
    record['passed'] = all(entry['passed'] for entry in record['cases'])
    (output / 'results.json').write_text(json.dumps(record, indent=2) + '\n')
    if not record['passed']:
        raise SystemExit('Wayland lifecycle matrix FAILED; actual exits and observations retained')
    print('Passed 61 raw Wayland lifecycle cases; owned servers exited normally')


if __name__ == '__main__':
    main()
