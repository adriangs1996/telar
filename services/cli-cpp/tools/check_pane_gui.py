#!/usr/bin/env python3
"""Check pane commands through an actual C++ GUI attached to a private runtime."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time
from check_pane_agent_cli import Stack


def main():
    parser = argparse.ArgumentParser()
    for name in ['cpp', 'probe', 'gui', 'scratch', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    rows = []
    with tempfile.TemporaryDirectory(prefix='gui-', dir=args.scratch) as directory:
        root = Path(directory)
        stack = Stack(args.cpp.resolve(), root, args.probe.resolve())
        gui = None
        try:
            # An endpoint check establishes the runtime schema before the GUI attaches.
            endpoint = stack.invoke(['server', 'endpoint']).stdout.splitlines()
            assert endpoint[-1] == b'cqp00001', endpoint
            log = (root / 'gui.log').open('wb')
            gui = subprocess.Popen([str(args.gui.resolve()), '--socket', str(stack.socket), '--no-config'], env=stack.env, stdout=log, stderr=log)
            deadline = time.monotonic() + 20
            while True:
                clients = subprocess.run([str(args.probe.resolve()), 'clients', str(stack.socket)], env=stack.env, capture_output=True, check=True).stdout.splitlines()
                if clients:
                    client = clients[0].decode()
                    break
                if gui.poll() is not None or time.monotonic() > deadline:
                    log.flush()
                    raise RuntimeError((root / 'gui.log').read_text())
                time.sleep(.1)
            rows.append({'check': 'GUI completed the cqp00001 handshake and registered', 'passed': True})
            deadline = time.monotonic() + 10
            while True:
                visible = json.loads(stack.invoke(['pane', 'list', '--json']).stdout)
                candidates = [entry for entry in visible if entry['pane_id'] != stack.ids['pane_id']]
                if candidates:
                    pane = str(max(candidates, key=lambda entry: entry['pane_id'])['pane_id'])
                    break
                assert time.monotonic() < deadline, visible
                time.sleep(.1)
            def invoke(action, *tail):
                result = stack.invoke(['pane', action, *tail, '--client', client, '--json'])
                value = json.loads(result.stdout) if result.stdout else None
                rows.append({'action': action, 'status': result.returncode, 'stdout': value, 'stderr': result.stderr.decode()})
                assert result.returncode == 0, rows[-1]
                return value
            def panes():
                return json.loads(stack.invoke(['pane', 'list', '--json']).stdout)
            def count(wanted):
                deadline = time.monotonic() + 5
                while len(panes()) != wanted:
                    assert time.monotonic() < deadline, panes()
                    time.sleep(.05)
            invoke('focus', pane)
            before = len(panes())
            invoke('create')
            count(before + 1)
            invoke('split', pane, 'vertical')
            count(before + 2)
            invoke('resize', pane, 'left')
            assert invoke('fullscreen', pane)['value'] == 1
            assert invoke('fullscreen', pane)['value'] == 0
            invoke('scroll', pane, '-2')
            invoke('copy', pane, '0,0:1,0')
            other = next(str(entry['pane_id']) for entry in panes() if str(entry['pane_id']) != pane and entry['pane_id'] != stack.ids['pane_id'])
            invoke('close', other)
            count(before + 1)
            rows.append({'check': 'create/split/close topology confirmed by runtime', 'passed': True})
        finally:
            if gui and gui.poll() is None:
                gui.terminate()
                gui.wait(timeout=10)
            stack.close()
            args.output.write_text(json.dumps(rows, indent=2) + '\n')
    print(f'{len(rows)} GUI pane checks passed')


if __name__ == '__main__':
    main()
