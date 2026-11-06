#!/usr/bin/env python3
"""Verify import diagnostics and definition navigation using the real clangd LSP."""
import argparse
import json
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--file', type=Path, required=True)
    parser.add_argument('--symbol', default='LimitLedger')
    parser.add_argument('--expected', default='diagnostics.cppm')
    parser.add_argument('--timeout', type=int, default=300, help='Seconds for the first module cache build')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = args.file.resolve()
    content = source.read_text()
    offset = content.index(args.symbol)
    position = {'line': content[:offset].count('\n'), 'character': len(content[:offset].rsplit('\n', 1)[-1])}
    incoming = queue.Queue()
    with tempfile.TemporaryFile(mode='w+b') as log:
        process = subprocess.Popen([str(root / '.toolchain/bin/clangd'), '--experimental-modules-support',
                                    '--background-index=0', '--compile-commands-dir=' + str(args.build.resolve())],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
        def receive():
            try:
                while True:
                    length = None
                    while True:
                        line = process.stdout.readline()
                        if not line:
                            return
                        if line in (b'\r\n', b'\n'):
                            break
                        if line.lower().startswith(b'content-length:'):
                            length = int(line.split(b':', 1)[1])
                    if length is not None:
                        incoming.put(json.loads(process.stdout.read(length)))
            finally:
                incoming.put({'eof': True})
        threading.Thread(target=receive, daemon=True).start()
        def send(method, params=None, ident=None):
            message = {'jsonrpc': '2.0', 'method': method}
            if params is not None:
                message['params'] = params
            if ident is not None:
                message['id'] = ident
            data = json.dumps(message).encode()
            process.stdin.write(f'Content-Length: {len(data)}\r\n\r\n'.encode() + data)
            process.stdin.flush()
        def wait(predicate, timeout=None):
            timeout = timeout or args.timeout
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                message = incoming.get(timeout=max(0.1, deadline - time.monotonic()))
                if message.get('eof'):
                    raise RuntimeError('clangd closed its output')
                if predicate(message):
                    return message
            raise RuntimeError('clangd response timed out')
        try:
            send('initialize', {'processId': None, 'rootUri': root.as_uri(), 'capabilities': {}}, 1)
            wait(lambda m: m.get('id') == 1)
            send('initialized', {})
            send('textDocument/didOpen', {'textDocument': {'uri': source.as_uri(), 'languageId': 'cpp', 'version': 1, 'text': content}})
            diagnostics = wait(lambda m: m.get('method') == 'textDocument/publishDiagnostics'
                               and m.get('params', {}).get('uri') == source.as_uri())['params']['diagnostics']
            errors = [d for d in diagnostics if d.get('severity') == 1]
            if errors:
                raise RuntimeError('Import diagnostics: ' + json.dumps(errors))
            send('textDocument/definition', {'textDocument': {'uri': source.as_uri()}, 'position': position}, 2)
            response = wait(lambda m: m.get('id') == 2)
            locations = response.get('result') or []
            if isinstance(locations, dict):
                locations = [locations]
            if not any(args.expected in location.get('uri', location.get('targetUri', '')) for location in locations):
                raise RuntimeError('Definition navigation did not reach ' + args.expected + ': ' + json.dumps(response))
            print(f'clangd: zero error diagnostics; {args.symbol} resolves to {args.expected}')
            send('shutdown', ident=3)
            wait(lambda m: m.get('id') == 3, timeout=10)
            send('exit')
            process.wait(timeout=10)
        except Exception:
            log.seek(0)
            print(log.read().decode(errors='replace'))
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    main()
