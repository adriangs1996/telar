#!/usr/bin/env python3
"""Native clipboard -> runtime -> CLI on a private headless Wayland session."""
import argparse
import io
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from PIL import Image

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'lib/clipboard/tests'))
from linux_clipboard_test import selection, stop, wait_for


def check(cli, root):
    config = root / 'sway.conf'
    config.write_text('xwayland disable\noutput * mode 640x480\nseat seat0 fallback true\n')
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(XDG_RUNTIME_DIR=str(root), WLR_BACKENDS='headless', WLR_RENDERER='pixman', WLR_LIBINPUT_NO_DEVICES='1')
    for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK'):
        env.pop(name, None)
    with (root / 'sway.log').open('wb') as log:
        compositor = subprocess.Popen(['sway', '-c', str(config)], env=env, stdout=log, stderr=log)
    runtime = None
    try:
        wait_for(lambda: any(path.is_socket() for path in root.glob('wayland-*')), compositor, 10)
        env['WAYLAND_DISPLAY'] = next(path.name for path in root.glob('wayland-*') if path.is_socket())
        endpoint = root / 'runtime.sock'
        with (root / 'runtime.log').open('wb') as log:
            runtime = subprocess.Popen([str(cli.with_name('telar-runtime')), '--socket', str(endpoint), '--no-config',
                                        '--history', ':memory:', '--no-session'], env=env, stdout=log, stderr=log)
        wait_for(endpoint.exists, runtime, 10)

        def get():
            return subprocess.run([str(cli), 'clipboard', 'get', '--socket', str(endpoint)],
                                  env=env, capture_output=True, timeout=12, stdin=subprocess.DEVNULL)

        assert get().returncode != 0
        image = Image.frombytes('RGB', (1024, 1024), os.urandom(1024 * 1024 * 3))
        cases = [('text/plain;charset=utf-8', 'UTF-8: á\n\x00'.encode()), ('text/plain', b'')]
        for encoding, mime in [('PNG', 'image/png'), ('JPEG', 'image/jpeg'), ('TIFF', 'image/tiff')]:
            data = io.BytesIO()
            image.save(data, format=encoding)
            cases.append((mime, data.getvalue()))
        for mime, data in cases:
            with selection('wayland', env, root, mime, data):
                result = get()
                assert result.returncode == 0 and result.stdout == data and not result.stderr, result.stderr
            print(f'Runtime clipboard: {mime}, {len(data)} byte-exact bytes', flush=True)

        with selection('wayland', env, root, 'image/png', b'x' * (32 * 1024 * 1024 + 1)):
            result = get()
            assert result.returncode != 0 and not result.stdout and b'max_capture_bytes' in result.stderr, result.stderr

        with selection('wayland', env, root, 'image/png', cases[2][1]) as owner:
            os.kill(owner.pid, signal.SIGSTOP)
            try:
                with (root / 'stalled-output').open('wb') as output:
                    stalled = subprocess.Popen([str(cli), 'clipboard', 'get', '--socket', str(endpoint)],
                                               env=env, stdout=output, stderr=subprocess.PIPE)
                time.sleep(.2)
                # The blocked clipboard owner must not block runtime control operations.
                status = subprocess.run([str(cli), 'runtime', 'status', '--socket', str(endpoint)],
                                        env=env, capture_output=True, timeout=2)
                assert status.returncode == 0, status.stderr
                _, error = stalled.communicate(timeout=8)
                assert stalled.returncode != 0 and b'timed out' in error
            finally:
                os.kill(owner.pid, signal.SIGCONT)
    finally:
        if runtime is not None:
            stop(runtime)
        stop(compositor)
    print('Native runtime clipboard integration passed. Desktop clipboard untouched.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telar', type=Path, required=True)
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='telar-runtime-clip-', dir='/tmp') as directory:
        root = Path(directory)
        root.chmod(0o700)
        check(arguments.telar.resolve(), root)
