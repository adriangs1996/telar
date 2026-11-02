import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time
import zlib


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def png(width, height, scanlines):
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(scanlines)) + chunk(b'IEND', b'')


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def wait_for(predicate, process, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        if process.poll() is not None:
            raise RuntimeError('Owned fixture exited before readiness: ' + str(process.returncode))
        time.sleep(.02)
    raise TimeoutError('Owned fixture did not become ready')


def main():
    parser = argparse.ArgumentParser(description='Exercise native clipboard capture on an owned headless Wayland display, including a stalled external provider')
    parser.add_argument('--provider', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline', action='store_true', help='Run the same Qt binary with a window but without constructing the clipboard worker')
    options = parser.parse_args()
    for command in ('sway', 'wtype'):
        if not shutil.which(command):
            parser.error('Missing explicit fixture dependency: ' + command)
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    provider, probe = options.provider.resolve(), options.probe.resolve()
    receipt = dict(recorded_at=datetime.now(timezone.utc).isoformat(), binaries={str(path): sha(path) for path in (provider, probe)}, executions=[], scope='Owned Wayland display and virtual keyboard; no user display or clipboard. Component transfer correctness and GUI responsiveness only; no visual or comparative performance acceptance.')
    receipt['sanitizers'] = {name: os.environ.get(name) for name in ('ASAN_OPTIONS', 'UBSAN_OPTIONS', 'LSAN_OPTIONS')}
    receipt['dbus_session_present'] = bool(os.environ.get('DBUS_SESSION_BUS_ADDRESS'))
    rgba = bytes([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255, 17, 34, 51, 255])
    scanlines = b''.join(b'\0' + rgba[row * 8:(row + 1) * 8] for row in range(3))
    fixtures = [('normal', 'ok', 0, png(2, 3, scanlines)), ('empty', 'NoImageOnClipboard', 0, b''), ('invalid', 'InvalidClipboardImage', 0, b'invalid PNG'), ('pixels', 'ClipboardPixelsTooLarge', 0, png(7000, 6000, scanlines)), ('source', 'ClipboardSourceTooLarge', 0, None), ('stall', 'ClipboardReadFailed', 8000, png(2, 3, scanlines))]
    if options.baseline:
        fixtures = [('baseline', 'baseline', 0, png(2, 3, scanlines))]
        receipt['scope'] = 'Control only: same binary, Qt initialization/window, provider and owned compositor; no clipboard worker constructed.'
    with tempfile.TemporaryDirectory(prefix='telar-clipboard-') as temporary:
        runtime = Path(temporary)
        runtime.chmod(0o700)
        config = output / 'sway.conf'
        config.write_text('xwayland disable\noutput * mode 1024x768\nseat seat0 fallback true\nfocus_follows_mouse no\ndefault_border none\n')
        environment = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), WLR_BACKENDS='headless', WLR_RENDERER='pixman', WLR_LIBINPUT_NO_DEVICES='1', QT_QPA_PLATFORM='wayland', QT_QUICK_BACKEND='software')
        environment.pop('DISPLAY', None)
        environment.pop('WAYLAND_DISPLAY', None)
        compositor_command = ['sway', '-c', str(config), '-d']
        with (output / 'compositor.log').open('w') as log:
            compositor = subprocess.Popen(compositor_command, env=environment, stdout=log, stderr=subprocess.STDOUT)
        keyboard = None
        receipt['compositor'] = dict(pid=compositor.pid, command=compositor_command)
        try:
            wait_for(lambda: any(path.is_socket() for path in runtime.glob('wayland-*')), compositor, 10)
            environment['WAYLAND_DISPLAY'] = next(path.name for path in runtime.glob('wayland-*') if path.is_socket())
            with (output / 'keyboard.log').open('w') as log:
                keyboard = subprocess.Popen(['wtype', '-s', '600000'], env=environment, stdout=log, stderr=subprocess.STDOUT)
            receipt['keyboard'] = dict(pid=keyboard.pid, command=['wtype', '-s', '600000'])
            time.sleep(.1)
            for name, expected, delay, image in fixtures:
                case = output / name
                case.mkdir()
                incoming = case / 'input.png'
                if image is None:
                    with incoming.open('wb') as target:
                        for _ in range(32):
                            target.write(bytes([0x5a]) * (1024 * 1024))
                        target.write(bytes([0x5a]))
                else:
                    incoming.write_bytes(image)
                ready = case / 'provider.ready'
                command = [str(provider), str(incoming), str(ready), str(delay)]
                with (case / 'provider.log').open('w') as log:
                    owner = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT)
                record = dict(name=name, provider_pid=owner.pid, provider_command=command, input_sha256=sha(incoming), expected=expected)
                receipt['executions'].append(record)
                try:
                    wait_for(lambda: Path(str(ready) + '.mapped').exists(), owner, 10)
                    input_command = ['wtype', '-k', 'F24']
                    injected = subprocess.run(input_command, env=environment, capture_output=True, timeout=5)
                    record['input'] = dict(command=input_command, exit_code=injected.returncode, stdout=injected.stdout.decode(errors='replace'), stderr=injected.stderr.decode(errors='replace'))
                    injected.check_returncode()
                    wait_for(ready.exists, owner, 10)
                    command = [str(probe), expected, str(case / 'observation.json')]
                    with (case / 'probe.log').open('w') as log:
                        result = subprocess.run(command, env=dict(environment, WAYLAND_DEBUG='1'), stdout=log, stderr=subprocess.STDOUT, timeout=20)
                    record.update(command=command, exit_code=result.returncode)
                    (output / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')
                    result.check_returncode()
                    observation = json.loads((case / 'observation.json').read_text())
                    record['observation'] = observation
                    assert observation['outcome'] == expected and observation['snapshot_us'] < 500000, name
                    if expected == 'ok':
                        assert observation['png_sha256'] == sha(incoming)
                        assert observation['thumbnail_sha256'] == hashlib.sha256(rgba).hexdigest()
                        assert observation['full_sha256'] == hashlib.sha256(rgba).hexdigest()
                    if name == 'stall':
                        assert observation['heartbeats'] >= 50 and 4900 <= observation['elapsed_ms'] < 7500
                finally:
                    stop(owner)
                    record['provider_exit'] = owner.returncode
                    (output / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')
        finally:
            if keyboard is not None:
                stop(keyboard)
            stop(compositor)
            receipt['compositor_exit'] = compositor.returncode
            receipt['keyboard_exit'] = keyboard.returncode if keyboard is not None else None
            (output / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert all(sha(path) == receipt['binaries'][str(path)] for path in (provider, probe)), 'A fixture binary changed during qualification'
    print('Passed', len(receipt['executions']), 'owned Wayland clipboard cases')


if __name__ == '__main__':
    main()
