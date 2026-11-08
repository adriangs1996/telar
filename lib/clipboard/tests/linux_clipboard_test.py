"""Exercise the native reader on private Wayland and X11 sessions only."""
import argparse
from contextlib import contextmanager
import io
import os
from pathlib import Path
import pty
import signal
import subprocess
import sys
import tempfile
import time

from PIL import Image

TOOLS = Path(__file__).resolve().parents[3] / 'src/gui-cpp/tools'
sys.path.insert(0, str(TOOLS))
from check_wayland_clipboard import stop, wait_for


def run(binary, environment, *arguments):
    return subprocess.run([str(binary), *map(str, arguments)], env=environment,
                          capture_output=True, timeout=9)


@contextmanager
def selection(backend, environment, root, mime, data):
    incoming = root / 'input'
    incoming.write_bytes(data)
    command = (['wl-copy', '--foreground', '--type', mime] if backend == 'wayland'
               else ['xclip', '-selection', 'clipboard', '-in', '-target', mime, '-quiet'])
    query = (['wl-paste', '--list-types'] if backend == 'wayland'
             else ['xclip', '-selection', 'clipboard', '-out', '-target', 'TARGETS'])
    with incoming.open('rb') as source, (root / 'provider.log').open('wb') as log:
        owner = subprocess.Popen(command, env=environment, stdin=source, stdout=log, stderr=log)
    try:
        def ready():
            reply = subprocess.run(query, env=environment, capture_output=True, timeout=2)
            return reply.returncode == 0 and mime.encode() in reply.stdout.splitlines()
        wait_for(ready, owner, 5)
        yield owner
    finally:
        stop(owner)


def check_cases(binary, backend, environment, root):
    empty = run(binary, environment)
    assert empty.returncode == 1 and not empty.stdout and b'no supported' in empty.stderr, empty
    text = ('UTF-8: áéíóú 🧵\n' + 'x' * (128 * 1024)).encode()
    image = Image.frombytes('RGB', (1024, 1024), os.urandom(1024 * 1024 * 3))
    cases = [('text/plain;charset=utf-8', text), ('text/plain;charset=utf-8', b''),
             ('text/plain;charset=utf-8', b'first\r\nsecond\0third\n'),
             ('UTF8_STRING', text), ('text/plain', text)]
    for encoding, mime in [('PNG', 'image/png'), ('JPEG', 'image/jpeg'), ('TIFF', 'image/tiff')]:
        encoded = io.BytesIO()
        image.save(encoded, format=encoding)
        assert len(encoded.getvalue()) > 2048
        cases.append((mime, encoded.getvalue()))
    for index, (mime, data) in enumerate(cases):
        with selection(backend, environment, root, mime, data):
            result = run(binary, environment)
            assert result.returncode == 0 and result.stdout == data and not result.stderr, result.stderr
            output = root / f'output-{index}'
            result = run(binary, environment, '--output', output)
            assert result.returncode == 0 and not result.stdout, result.stderr
            expected_mime = mime if mime.startswith('image/') else 'text/plain'
            assert expected_mime.encode() in result.stderr and output.read_bytes() == data
            if mime.startswith('image/'):
                master, slave = pty.openpty()
                try:
                    terminal = subprocess.run([str(binary)], env=environment, stdout=slave,
                                              stderr=subprocess.PIPE, timeout=9)
                    assert terminal.returncode == 1 and b'--output' in terminal.stderr
                finally:
                    os.close(master)
                    os.close(slave)
        print(f'{backend}: {mime}, {len(data)} bytes, exact stdout/file output', flush=True)
    with selection(backend, environment, root, 'image/png', b'x' * (32 * 1024 * 1024 + 1)):
        rejected = run(binary, environment)
        assert rejected.returncode == 1 and not rejected.stdout and b'byte limit' in rejected.stderr, rejected.stderr
        print(f'{backend}: oversized capture rejected before publishing bytes', flush=True)

    with selection(backend, environment, root, 'application/x-telar-unsupported', b'unsupported'):
        rejected = run(binary, environment)
        assert rejected.returncode == 1 and not rejected.stdout and b'no supported' in rejected.stderr

    missing = dict(environment)
    missing.pop('WAYLAND_DISPLAY', None)
    missing.pop('DISPLAY', None)
    rejected = run(binary, missing)
    assert rejected.returncode == 1 and not rejected.stdout and b'graphical session' in rejected.stderr
    png_data = next(data for mime, data in cases if mime == 'image/png')
    if backend == 'x11':
        missing['WAYLAND_DISPLAY'] = str(root / 'nonexistent-wayland')
        rejected = run(binary, missing)
        assert rejected.returncode == 1 and not rejected.stdout and b'graphical session' in rejected.stderr
        check_x11_protocol(binary, environment, root, png_data)
    else:
        with selection(backend, environment, root, 'image/png', png_data) as owner:
            os.kill(owner.pid, signal.SIGSTOP)
            try:
                started = time.monotonic()
                result = run(binary, environment)
                assert result.returncode == 1 and not result.stdout and b'timed out' in result.stderr
                assert 4.5 <= time.monotonic() - started < 8
                print('wayland: stalled provider timed out without partial output', flush=True)
            finally:
                os.kill(owner.pid, signal.SIGCONT)


def check_x11_protocol(binary, environment, root, image):
    incoming = root / 'protocol-input.png'
    incoming.write_bytes(image)
    cases = [('direct', None), ('incr', None), ('unannounced', None), ('declared', None),
             ('prefix-failure', b'transfer clipboard'), ('prefix-stall', b'timed out'),
             ('incr-empty', b'transfer clipboard'), ('incr-format', b'transfer clipboard'),
             ('owner-change', b'changed'), ('refused', b'no supported')]
    for mode, expected in cases:
        ready = root / f'{mode}.ready'
        command = [sys.executable, str(TOOLS / 'clipboard_x11_provider.py'), '--input', str(incoming),
                   '--ready', str(ready), '--mode', mode]
        with (root / f'{mode}.log').open('wb') as log:
            provider = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
        try:
            wait_for(ready.exists, provider, 5)
            started = time.monotonic()
            result = run(binary, environment)
            if expected is None:
                assert result.returncode == 0 and result.stdout == image, (mode, result.stderr)
            else:
                assert result.returncode == 1 and not result.stdout and expected in result.stderr, (mode, result.stderr)
                if mode == 'prefix-stall':
                    assert 4.5 <= time.monotonic() - started < 8
            print(f'x11 protocol: {mode} passed', flush=True)
        finally:
            stop(provider)


def wayland(binary, root):
    config = root / 'sway.conf'
    config.write_text('xwayland disable\noutput * mode 640x480\nseat seat0 fallback true\n')
    environment = dict(os.environ, XDG_RUNTIME_DIR=str(root), WLR_BACKENDS='headless',
                       WLR_RENDERER='pixman', WLR_LIBINPUT_NO_DEVICES='1')
    for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK'):
        environment.pop(name, None)
    with (root / 'sway.log').open('wb') as log:
        compositor = subprocess.Popen(['sway', '-c', str(config)], env=environment,
                                      stdout=log, stderr=log)
    try:
        wait_for(lambda: any(path.is_socket() for path in root.glob('wayland-*')), compositor, 10)
        environment['WAYLAND_DISPLAY'] = next(path.name for path in root.glob('wayland-*') if path.is_socket())
        check_cases(binary, 'wayland', environment, root)
    finally:
        stop(compositor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--backend', choices=('wayland', 'x11'), required=True)
    parser.add_argument('--owned-x11', type=Path, help=argparse.SUPPRESS)
    options = parser.parse_args()
    binary = options.binary.resolve()
    if options.owned_x11:
        root = options.owned_x11
        assert os.environ.get('TELAR_CLIPBOARD_OWNED_X11') == (root / 'owner').read_text()
        check_cases(binary, 'x11', os.environ, root)
        return
    with tempfile.TemporaryDirectory(prefix='telar-clipboard-linux-') as directory:
        root = Path(directory)
        root.chmod(0o700)
        if options.backend == 'wayland':
            wayland(binary, root)
        else:
            nonce = os.urandom(16).hex()
            (root / 'owner').write_text(nonce)
            environment = dict(os.environ, TELAR_CLIPBOARD_OWNED_X11=nonce)
            environment.pop('WAYLAND_DISPLAY', None)
            arguments = ['xvfb-run', '-a', '-f', str(root / 'Xauthority'), '-e', str(root / 'xvfb.log'),
                         '-s', '-screen 0 640x480x24 -nolisten tcp', sys.executable, str(Path(__file__).resolve()),
                         str(binary), '--backend', 'x11', '--owned-x11', str(root)]
            subprocess.run(arguments, env=environment, check=True, timeout=75)
    print(f'Passed {options.backend} clipboard integration. User clipboard untouched.')


if __name__ == '__main__':
    main()
