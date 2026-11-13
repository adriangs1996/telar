"""Exercise clipboard transfers in an authenticated, owned Xvfb server."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid

from check_wayland_clipboard import png, stop, wait_for


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def collect(options):
    output = options.output.resolve()
    assert os.environ.get('TELAR_OWNED_X11_FIXTURE') == (output / 'owner').read_text()
    provider, probe = options.provider.resolve(), options.probe.resolve()
    native = Path(__file__).resolve().with_name('clipboard_x11_provider.py')
    rgba = bytes([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255, 17, 34, 51, 255])
    scanlines = b''.join(b'\0' + rgba[row * 8:(row + 1) * 8] for row in range(3))
    image = png(2, 3, scanlines)
    fixtures = output / 'fixtures'
    fixtures.mkdir()
    (fixtures / 'normal.png').write_bytes(image)
    (fixtures / 'empty.png').write_bytes(b'')
    (fixtures / 'invalid.png').write_bytes(b'invalid PNG')
    (fixtures / 'pixels.png').write_bytes(png(7000, 6000, scanlines))
    (fixtures / 'padded.png').write_bytes(image + b'\0' * 262144)
    with (fixtures / 'source.bin').open('wb') as stream:
        for _ in range(32):
            stream.write(b'Z' * 1048576)
        stream.write(b'Z')
    cases = [('qt-normal', 'qt', 'normal.png', 'ok'), ('qt-empty', 'qt', 'empty.png', 'NoImageOnClipboard'), ('qt-stall', 'qt-stall', 'normal.png', 'ClipboardReadFailed'), ('qt-cancel', 'qt-cancel', 'normal.png', 'cancelled'), ('incr', 'incr', 'normal.png', 'ok'), ('chunks', 'incr', 'padded.png', 'ok'), ('prefix-failure', 'prefix-failure', 'normal.png', 'ClipboardReadFailed'), ('prefix-stall', 'prefix-stall', 'normal.png', 'ClipboardReadFailed'), ('empty', 'incr-empty', 'normal.png', 'NoImageOnClipboard'), ('format', 'incr-format', 'normal.png', 'ClipboardReadFailed'), ('declared', 'declared', 'normal.png', 'ClipboardSourceTooLarge'), ('unannounced', 'unannounced', 'source.bin', 'ClipboardSourceTooLarge'), ('owner-change', 'owner-change', 'normal.png', 'ok'), ('refused', 'refused', 'normal.png', 'NoImageOnClipboard'), ('invalid', 'direct', 'invalid.png', 'InvalidClipboardImage'), ('pixels', 'direct', 'pixels.png', 'ClipboardPixelsTooLarge')]
    receipt = dict(recorded_at=datetime.now(timezone.utc).isoformat(), scope='Owned Xvfb/clipboard/provider only; transfer correctness and GUI responsiveness, no global visual or comparative performance acceptance.', binaries={str(path): sha(path) for path in (provider, probe)}, sources={str(path): sha(path) for path in (Path(__file__).resolve(), native)}, sanitizers={name: os.environ.get(name) for name in ('ASAN_OPTIONS', 'UBSAN_OPTIONS', 'LSAN_OPTIONS')}, dbus_session_present=bool(os.environ.get('DBUS_SESSION_BUS_ADDRESS')), display=os.environ.get('DISPLAY'), executions=[])
    for name, mode, incoming, expected in cases:
        case = output / name
        case.mkdir()
        image_file = fixtures / incoming
        ready = case / 'provider.ready'
        command = [str(provider), str(image_file), str(ready), '8000' if mode in ('qt-stall', 'qt-cancel') else '0'] if mode.startswith('qt') else [sys.executable, str(native), '--input', str(image_file), '--ready', str(ready), '--mode', mode]
        with (case / 'provider.log').open('wb') as log:
            owner = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        record = dict(name=name, provider_command=command, owned_provider_pid=owner.pid, input_sha256=sha(image_file), expected=expected)
        receipt['executions'].append(record)
        try:
            wait_for(ready.exists, owner, 10)
            with (case / 'probe.log').open('wb') as log:
                result = subprocess.run([str(probe), expected, str(case / 'observation.json')], stdout=log, stderr=subprocess.STDOUT, timeout=20)
            record['actual_probe_exit'] = result.returncode
            record['observation'] = json.loads((case / 'observation.json').read_text())
            assert result.returncode == 0, record
            observed = record['observation']
            assert observed['outcome'] == expected and observed['snapshot_us'] < 500000
            if expected == 'ok':
                assert observed['png_sha256'] == record['input_sha256']
                assert observed['full_sha256'] == observed['thumbnail_sha256'] == hashlib.sha256(rgba).hexdigest()
            else:
                assert 'png_sha256' not in observed, 'A failed transfer must never publish an image'
            if mode in ('qt-stall', 'prefix-stall'):
                assert observed['heartbeats'] >= 50 and 4900 <= observed['elapsed_ms'] < 7500
            if mode == 'qt-cancel':
                assert 0 <= observed['retirement_us'] < 500000 and observed['elapsed_ms'] < 1500
            print(name, observed['outcome'], observed['snapshot_us'], observed['heartbeats'], flush=True)
        finally:
            stop(owner)
            record['provider_cleanup_exit'] = owner.returncode
            (output / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert all(sha(Path(path)) == identity for path, identity in receipt['binaries'].items())
    receipt['passed'] = True
    (output / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--inside-server', action='store_true', help=argparse.SUPPRESS)
    options = parser.parse_args()
    if options.inside_server:
        collect(options)
        return
    for command in ('xvfb-run', 'Xvfb', 'xauth', 'dbus-run-session'):
        if not shutil.which(command):
            parser.error('Missing explicit fixture dependency: ' + command)
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    nonce = str(uuid.uuid4())
    (output / 'owner').write_text(nonce)
    authority = output / 'Xauthority'
    environment = dict(os.environ, TELAR_OWNED_X11_FIXTURE=nonce, QT_QPA_PLATFORM='xcb', QT_QUICK_BACKEND='software')
    arguments = ['xvfb-run', '-a', '-f', str(authority), '-e', str(output / 'xvfb.log'), '-s', '-screen 0 1024x768x24 -nolisten tcp', 'dbus-run-session', '--', sys.executable, str(Path(__file__).resolve()), '--inside-server', '--provider', str(options.provider.resolve()), '--probe', str(options.probe.resolve()), '--output', str(output)]
    process = subprocess.Popen(arguments, env=environment, start_new_session=True)
    try:
        actual_exit = process.wait(timeout=120)
    except BaseException:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
        raise
    finally:
        authority.unlink(missing_ok=True)
    (output / 'server-exit.json').write_text(json.dumps(dict(actual_exit=actual_exit, command=arguments, owned_controller_pid=process.pid, private_authority_removed=not authority.exists()), indent=2) + '\n')
    if actual_exit:
        raise SystemExit(actual_exit)
    print('Passed16 owned X11 clipboard cases')


if __name__ == '__main__':
    main()
