import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

from tab_switch_report import publication_events


@unittest.skipUnless(sys.platform == 'darwin', 'native macOS producer clock')
class TabFixtureTest(unittest.TestCase):
    def test_four_producers_survive_marker_controls_and_resize(self):
        with tempfile.TemporaryDirectory(prefix='telar-tab-fixtures-') as temporary:
            directory = Path(temporary)
            source = Path(__file__).resolve().parent
            for name in ('tab_switch_fixture.py', 'tab_switch_packet.py', 'terminal_bench_fixture.py'):
                shutil.copy2(source / name, directory / name)
            subprocess.run(['clang', '-dynamiclib', '-O2', '-Wall', '-Wextra', '-Werror',
                            str(source / 'tab_switch_clock.c'), '-o', str(directory / 'tab_switch_clock.dylib')], check=True)
            children, descriptors, output = [], [], {}

            def pump_until(predicate):
                deadline = time.monotonic() + 5
                while True:
                    for descriptor in select.select(descriptors, [], [], .01)[0]:
                        try:
                            output[descriptor].extend(os.read(descriptor, 65536))
                        except OSError as error:
                            if error.errno != errno.EIO:
                                raise
                    self.assertTrue(all(child.poll() is None for child in children), output)
                    if predicate():
                        return
                    self.assertLess(time.monotonic(), deadline, output)

            def receipt(index, generic=False):
                path = (directory / 'receipts' / f'{children[index].pid}.json' if generic else
                        directory / 'switching' / f'{index}.json')
                return json.loads(path.read_text()) if path.exists() else {}

            try:
                for index in range(4):
                    master, slave = pty.openpty()
                    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 82, 0, 0))
                    os.set_blocking(master, False)
                    environment = dict(os.environ, TELAR_PANE_ID=str(index + 1), TELAR_PANE_GENERATION='1',
                                       TELAR_TAB_ID=str(index + 10), TELAR_WORKSPACE_ID='1')
                    child = subprocess.Popen([sys.executable, str(directory / 'tab_switch_fixture.py'), str(directory)],
                                             stdin=slave, stdout=slave, stderr=slave, env=environment, start_new_session=True)
                    os.close(slave)
                    children.append(child)
                    descriptors.append(master)
                    output[master] = bytearray()
                    pump_until(lambda: receipt(index).get('generation', 0) >= 1)
                pump_until(lambda: all(receipt(index).get('generation', 0) >= 10 for index in range(4)))
                for index in range(4):
                    observed = receipt(index)
                    self.assertEqual(observed['pid'], children[index].pid)
                    self.assertEqual(observed['identities']['TELAR_TAB_ID'], index + 10)
                    self.assertIsNone(observed['error'])
                    self.assertEqual(observed['phase'], 'ready')
                    self.assertIn(b'\x1b[48;2;230;20;60m ', output[descriptors[index]])
                primary = descriptors[0]
                output[primary].clear()
                os.write(primary, b'c')
                pump_until(lambda: b'\x1b[48;2;180;180;180m ' in output[primary])
                output[primary].clear()
                os.write(primary, b'r')
                pump_until(lambda: b'\x1b[48;2;230;20;60m ' in output[primary])
                generation = receipt(0)['generation']
                fcntl.ioctl(primary, termios.TIOCSWINSZ, struct.pack('HHHH', 25, 84, 0, 0))
                children[0].send_signal(signal.SIGWINCH)
                pump_until(lambda: receipt(0).get('cols') == 84 and receipt(0).get('generation', 0) > generation)
                for child in children:
                    child.terminate()
                for child in children:
                    self.assertEqual(child.wait(timeout=5), 0)
                for index in range(4):
                    observed = receipt(index)
                    self.assertEqual(observed['phase'], 'finished')
                    self.assertIsNone(observed['error'])
                    events = publication_events((directory / 'switching' / f'{index}.events').read_bytes())
                    self.assertEqual(len(events), observed['publications'])
                    self.assertEqual(observed['generation'], observed['publications'])
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                        child.wait()
                for descriptor in descriptors:
                    os.close(descriptor)

    def test_shutdown_during_publication_finishes_its_receipt(self):
        with tempfile.TemporaryDirectory(prefix='telar-tab-shutdown-') as temporary:
            directory = Path(temporary)
            source = Path(__file__).resolve().parent
            for name in ('tab_switch_fixture.py', 'tab_switch_packet.py', 'terminal_bench_fixture.py'):
                shutil.copy2(source / name, directory / name)
            subprocess.run(['clang', '-dynamiclib', '-O2', '-Wall', '-Wextra', '-Werror',
                            str(source / 'tab_switch_clock.c'), '-o', str(directory / 'tab_switch_clock.dylib')], check=True)
            driver = directory / 'interrupt_publication.py'
            driver.write_text('''import os, signal, sys
from pathlib import Path
from tab_switch_fixture import TabFixture

class InterruptedFixture(TabFixture):
    def draw_marker(self):
        super().draw_marker()
        if self.generation == 3:
            os.kill(os.getpid(), signal.SIGTERM)

InterruptedFixture(Path(sys.argv[1])).run()
''')
            master, slave = pty.openpty()
            child = None
            try:
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 82, 0, 0))
                environment = dict(os.environ, TELAR_PANE_ID='1', TELAR_PANE_GENERATION='1',
                                   TELAR_TAB_ID='1', TELAR_WORKSPACE_ID='1')
                child = subprocess.Popen([sys.executable, str(driver), str(directory)],
                                         stdin=slave, stdout=slave, stderr=slave, env=environment, start_new_session=True)
                os.close(slave)
                slave = None
                self.assertEqual(child.wait(timeout=5), 0)
                receipt = json.loads((directory / 'switching/0.json').read_text())
                events = publication_events((directory / 'switching/0.events').read_bytes())
                self.assertEqual(receipt['phase'], 'finished')
                self.assertIsNone(receipt['error'])
                self.assertEqual(receipt['generation'], 3)
                self.assertEqual(receipt['publications'], 3)
                self.assertEqual(len(events), 3)
            finally:
                if child is not None and child.poll() is None:
                    child.kill()
                    child.wait()
                os.close(master)
                if slave is not None:
                    os.close(slave)


if __name__ == '__main__':
    unittest.main()
