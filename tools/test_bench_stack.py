import os
from pathlib import Path
import socket
import sys
import tempfile
import unittest

from bench_stack import runtime_identity, staged_runtime


class StackIdentityTest(unittest.TestCase):
    def test_missing_socket_does_not_wait_indefinitely(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as temporary:
            with self.assertRaisesRegex(TimeoutError, 'did not become ready'):
                runtime_identity(Path(temporary) / 'missing.sock', sys.executable, timeout=0)

    def test_missing_or_wrong_adjacent_helper_rejects_the_pair(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            gui, runtime, helper = root / 'gui', root / 'runtime', root / 'telar'
            gui.write_bytes(b'gui')
            runtime.write_bytes(b'candidate')
            with self.assertRaisesRegex(ValueError, 'Stage'):
                staged_runtime(gui, runtime)
            helper.write_bytes(b'installed-reference')
            helper.chmod(0o700)
            with self.assertRaisesRegex(ValueError, 'differs'):
                staged_runtime(gui, runtime)
            helper.write_bytes(runtime.read_bytes())
            identity = staged_runtime(gui, runtime)
            self.assertEqual(identity['path'], str(helper.resolve()))
            helper.chmod(0o600)
            with self.assertRaisesRegex(ValueError, 'Stage'):
                staged_runtime(gui, runtime)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS native socket peer identity')
    def test_socket_peer_must_match_the_selected_executable(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as temporary:
            path = Path(temporary) / 'runtime.sock'
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(path))
                server.listen(4)
                identity = runtime_identity(path, sys.executable)
                self.assertEqual(identity['pid'], os.getpid())
                with self.assertRaisesRegex(ValueError, 'unexpected executable'):
                    runtime_identity(path, '/bin/sh')


if __name__ == '__main__':
    unittest.main()
