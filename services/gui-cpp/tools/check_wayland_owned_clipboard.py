"""Exercise self-owned Qt clipboard capture and retirement on private displays."""
import argparse
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile

from check_wayland_clipboard import png, sha, stop, wait_for


def execute(options, image, output, environment, control=None):
    arguments = [str(options.probe.resolve()), str(image), str(output / 'mapped'), str(output / 'observation.json'), ('protocol-queued' if options.queued else 'protocol') if control is not None else ('native-queued' if options.queued else 'native')]
    with (output / 'probe.log').open('wb') as log:
        probe = subprocess.Popen(arguments, stdin=control if control is not None else subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=environment)
    entry = dict(command=arguments, owned_probe_pid=probe.pid, input_sha256=sha(image))
    try:
        if control is None:
            wait_for((output / 'mapped').exists, probe, 10)
            command = ['wtype', '-k', 'F24']
            result = subprocess.run(command, env=environment, capture_output=True, timeout=5)
            entry['input'] = dict(command=command, actual_exit=result.returncode, stderr=result.stderr.decode(errors='replace'))
            result.check_returncode()
        entry['actual_probe_exit'] = probe.wait(timeout=20)
        entry['observation'] = json.loads((output / 'observation.json').read_text())
        entry['passed'] = entry['actual_probe_exit'] == 0 and entry['observation']['passed']
        if entry['passed']:
            initial = entry['observation']['cases'][0]
            entry['passed'] = initial.get('png_sha256') == sha(image)
        print(output.name, entry['actual_probe_exit'], entry['passed'], flush=True)
    finally:
        stop(probe)
        entry['cleanup_exit'] = probe.returncode
        (output / 'result.json').write_text(json.dumps(entry, indent=2) + '\n')
    return entry


def protocol(options, output, image, version):
    output.mkdir()
    runtime = output / 'r'
    runtime.mkdir(mode=0o700)
    environment = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM='wayland', QT_QUICK_BACKEND='software', QT_WAYLAND_SHELL_INTEGRATION='wl-shell', TELAR_WAYLAND_TEST_QT_CLIPBOARD='1')
    environment.pop('DISPLAY', None)
    environment.pop('WAYLAND_DISPLAY', None)
    server_end, probe_end = socket.socketpair()
    with (output / 'server.log').open('wb') as log:
        server = subprocess.Popen([str(options.server.resolve()), str(version), str(min(version, 3))], stdin=server_end, stdout=subprocess.PIPE, stderr=log, env=environment)
    server_end.close()
    try:
        assert select.select([server.stdout], [], [], 5)[0], 'Owned server readiness timeout'
        environment['WAYLAND_DISPLAY'] = server.stdout.readline().decode().strip()
        assert environment['WAYLAND_DISPLAY'].startswith('wayland-')
        entry = execute(options, image, output, environment, probe_end)
    finally:
        probe_end.close()
        try:
            actual_exit = server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            stop(server)
            actual_exit = server.returncode
        server.stdout.close()
        (output / 'server-exit.json').write_text(json.dumps(dict(owned_server_pid=server.pid, actual_exit=actual_exit), indent=2) + '\n')
    entry['passed'] = entry['passed'] and actual_exit == 0
    return entry


def native(options, output, images):
    output.mkdir()
    config = output / 'sway.conf'
    config.write_text('xwayland disable\noutput * mode 1024x768\nseat seat0 fallback true\nfocus_follows_mouse no\ndefault_border none\n')
    entries = []
    with tempfile.TemporaryDirectory(prefix='telar-self-clipboard-') as temporary:
        runtime = Path(temporary)
        runtime.chmod(0o700)
        environment = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), WLR_BACKENDS='headless', WLR_RENDERER='pixman', WLR_LIBINPUT_NO_DEVICES='1', QT_QPA_PLATFORM='wayland', QT_QUICK_BACKEND='software')
        environment.pop('DISPLAY', None)
        environment.pop('WAYLAND_DISPLAY', None)
        environment.pop('QT_WAYLAND_SHELL_INTEGRATION', None)
        with (output / 'compositor.log').open('wb') as log:
            compositor = subprocess.Popen(['sway', '-c', str(config), '-d'], stdout=log, stderr=subprocess.STDOUT, env=environment)
        keyboard = None
        try:
            wait_for(lambda: any(path.is_socket() for path in runtime.glob('wayland-*')), compositor, 10)
            environment['WAYLAND_DISPLAY'] = next(path.name for path in runtime.glob('wayland-*') if path.is_socket())
            with (output / 'keyboard.log').open('wb') as log:
                keyboard = subprocess.Popen(['wtype', '-s', '600000'], stdout=log, stderr=subprocess.STDOUT, env=environment)
            for image in images:
                directory = output / image.stem
                directory.mkdir()
                entries.append(execute(options, image, directory, environment))
        finally:
            if keyboard is not None:
                stop(keyboard)
            stop(compositor)
            (output / 'cleanup.json').write_text(json.dumps(dict(owned_compositor_pid=compositor.pid, compositor_exit=compositor.returncode, owned_keyboard_pid=keyboard.pid if keyboard else None, keyboard_exit=keyboard.returncode if keyboard else None), indent=2) + '\n')
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--queued', action='store_true', help='Hold the sole worker for1500ms and require GUI heartbeats within500ms')
    parser.add_argument('--mode', choices=('protocol', 'native', 'both'), default='both')
    options = parser.parse_args()
    output = options.output.resolve()
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    small = output / 'small.png'
    small.write_bytes(png(2, 3, b'\0' + bytes([255, 0, 0, 255]) * 2 + b'\0' + bytes([0, 255, 0, 255]) * 2 + b'\0' + bytes([0, 0, 255, 255]) * 2))
    large = output / 'large.png'
    large.write_bytes(small.read_bytes() + b'\0' * (1024 * 1024))
    record = dict(scope='Private Qt self-owned PNG worker capture and raw protocol retirement; no user display/clipboard', binaries={str(path.resolve()): sha(path.resolve()) for path in (options.probe, options.server)}, sanitizers={name: os.environ.get(name) for name in ('ASAN_OPTIONS', 'UBSAN_OPTIONS', 'LSAN_OPTIONS', 'LD_LIBRARY_PATH')}, dbus_session_present=bool(os.environ.get('DBUS_SESSION_BUS_ADDRESS')), executions=[])
    try:
        if options.mode in ('protocol', 'both'):
            for version in (8, 1):
                record['executions'].append(protocol(options, output / ('p' + str(version)), large if options.queued else small, version))
        if options.mode in ('native', 'both'):
            record['executions'].extend(native(options, output / 'native', [small, large]))
        assert all(sha(Path(path)) == identity for path, identity in record['binaries'].items())
        record['passed'] = all(entry['passed'] for entry in record['executions'])
    finally:
        (output / 'results.json').write_text(json.dumps(record, indent=2) + '\n')
    if not record['passed']:
        raise SystemExit('Owned Wayland clipboard qualification FAILED; actual exits retained')
    print('Passed owned Qt clipboard retirement and native worker controls')


if __name__ == '__main__':
    main()
