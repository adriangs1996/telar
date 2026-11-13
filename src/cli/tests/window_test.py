#!/usr/bin/env python3
"""CLI wire fixtures for window commands."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time


def exact(connection, size):
    data = bytearray()
    while len(data) < size:
        part = connection.recv(size - len(data))
        if not part:
            return None
        data.extend(part)
    return bytes(data)


def receive(connection):
    size = exact(connection, 4)
    return None if size is None else exact(connection, struct.unpack('<I', size)[0])


def send(connection, data):
    connection.sendall(struct.pack('<I', len(data)) + data)


def text(data):
    data = data.encode() if isinstance(data, str) else data
    return struct.pack('<H', len(data)) + data


def environment(root):
    result = {k: v for k, v in os.environ.items() if not k.startswith('TELAR_')}
    for key in ('HOME', 'XDG_RUNTIME_DIR', 'XDG_DATA_HOME', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'TMPDIR'):
        path = root / key.lower()
        path.mkdir(parents=True, exist_ok=True)
        result[key] = str(path)
    return result


def peer(listener, fixture, frames):
    listener.settimeout(5)
    try:
        connection, _ = listener.accept()
    except TimeoutError:
        return
    with connection:
        connection.settimeout(5)
        hello = receive(connection)
        assert hello[:9] == b'TELARIPC\x01'
        send(connection, b'TELARIPC\x02' + hello[9:])
        while (frame := receive(connection)) is not None:
            frames.append(frame.hex())
            request = frame[1:9]
            if fixture.get('silent'):
                time.sleep(31)
                return
            if frame[0] == 0x33:
                entries = b'' if fixture.get('empty') else struct.pack('<QQQHQQ', 7, 11, 19, 2, 23, 29)
                send(connection, b'\xad' + request + bytes([bool(entries)]) + entries)
            elif frame[0] == 0x34:
                assert struct.unpack('<QQ', frame[9:]) == (7, 11)
                send(connection, b'\xa1' + request)
            elif frame[0] == 0x35:
                action = frame[25]
                target, value = struct.unpack('<Qq', frame[27:43])
                status = fixture.get('status', 1)
                result = fixture.get('text', '')
                result_value = fixture.get('value', 0)
                if action in (29, 30) and not fixture.get('text'):
                    if action == 29:
                        items = [{'index': 0, 'path': 'fixture', 'id': 'test', 'version': '1', 'requested_enabled': True, 'enabled': True}] if value == 0 else [{'index': 1, 'path': 'disabled', 'id': '', 'version': '', 'requested_enabled': False, 'enabled': False}]
                    else:
                        items = [{'path': 'fixture', 'id': 'test', 'capabilities': []}] if value == 0 else ['run']
                    result = json.dumps({'generation': fixture.get('generation', 3), 'entries': items}, separators=(',', ':'))
                    result_value = 1 if value == 0 else -1
                identity = frame[9:25] if not fixture.get('bad_route') else struct.pack('<QQ', 9, 11)
                send(connection, b'\xaf' + request + identity + bytes([action, status]) + struct.pack('<Qq', target, result_value) + text(result))
            elif frame[0] == 0x29:
                send(connection, b'\xa9' + request + bytes([fixture.get('suggestion', 0)]) + text(fixture.get('text', 'printf "hello"')))
            elif frame[0] == 0x19:
                send(connection, b'\x9c' + request + bytes([fixture.get('delivered', 1)]))
            elif frame[0] == 0x43:
                pass
            else:
                raise AssertionError(f'Unexpected frame: {frame.hex()}')


def run_fixture(binary, root, words, fixture):
    path = root / 'fixture.sock'
    path.unlink(missing_ok=True)
    frames = []
    with socket.socket(socket.AF_UNIX) as listener, ThreadPoolExecutor(max_workers=1) as executor:
        listener.bind(str(path))
        listener.listen()
        future = executor.submit(peer, listener, fixture, frames)
        result = subprocess.run([str(binary), *words, '--socket', str(path)], env=environment(root), input=b'', capture_output=True, timeout=fixture.get('timeout',10))
        future.result(timeout=fixture.get('timeout',10))
    return {'status': result.returncode, 'stdout': result.stdout.decode(), 'stderr': result.stderr.decode(), 'frames': frames}


def cases():
    for words, expected in [(['client', 'list'], 'CLIENT\tGENERATION\tIDENTITY\tATTACHMENTS\tLAST INPUT PANE\n7\t11\t19\t2\t23\n'), (['client', 'get', '7'], '7\t11\t19\t2\t23\n'), (['client', 'detach', '7'], 'client 7 detached\n')]:
        yield words, {}, 0, expected
        yield words + ['--json'], {}, 0, None
    yield ['client', 'get', '8'], {}, 2, ''
    yield ['client', 'list', '--json'], {'empty': True}, 0, '[]\n'
    actions = [(['sidebar', 'get'], 12), (['sidebar', 'show'], 13), (['sidebar', 'hide'], 14), (['sidebar', 'resize', '48'], 15), (['workspace-list', 'expand'], 16), (['workspace-list', 'collapse'], 17), (['client', 'open', 'goto'], 18), (['client', 'open', 'history'], 19), (['client', 'copy-mode'], 20), (['notification', 'dismiss', '9'], 21), (['client', 'open-link', 'https://example.invalid'], 22), (['client', 'clipboard', 'copy', 'fixture'], 23), (['layout', 'get'], 25), (['layout', 'apply', 'token'], 26), (['config', 'reload'], 27), (['config', 'show'], 28), (['plugin', 'list'], 29), (['plugin', 'get', 'test'], 30), (['plugin', 'enable', 'test'], 31), (['plugin', 'disable', 'test'], 32), (['plugin', 'run', 'test', 'run'], 33)]
    for words, action in actions:
        fixture = {'text': 'visible', 'value': 48} if action == 12 else {'text': '{"escaped":"a\\b\\f\\u007f","list":[1,true,null]}'} if action == 28 else {}
        for flags in ([], ['--json']):
            yield words + ['--client', '7'] + flags, fixture, 0, None
        yield words + ['--client', '7'], {'empty': True}, 2, ''
        yield words + ['--client', '7'], {'status': 3, 'text': 'FixtureRefusal'}, 1, ''
    yield ['config','show','--client','7','--json'], {'text':'{"x":1.0,"y":1e2,"z":1e-20,"a":1e300,"b":-0.0,"c":1e999,"d":1e-999}'}, 0, '{"x":1,"y":100,"z":0.'+'0'*19+'1,"a":1'+'0'*300+',"b":-0,"c":1e999,"d":0}\n'
    yield ['sidebar', 'get', '--client', '7'], {'bad_route': True}, 1, ''
    yield ['plugin', 'list', '--client', '7'], {'generation': 0}, 1, ''
    for status in range(4):
        yield ['command', 'suggest', '23', 'list files', '--json'], {'suggestion': status, 'text': 'ls' if status == 0 else ''}, 3 if status == 2 else 0 if status == 0 else 1, None
    yield ['client', 'clipboard', 'copy', 'x'*4097, '--client', '7'], {}, 1, ''
    yield ['sidebar', 'hide', '--client', '7', '--json'], {'text': 'a\b\f\x7fé', 'value': -9223372036854775808}, 0, None
    yield ['notification', 'show', 'bad\ntext'], {}, 1, ''
    yield ['notification', 'show', 'Fixture', '--link', 'http://invalid'], {}, 1, ''
    yield ['notification','show','Fixture','--body','é'*300], {}, 1, ''
    yield ['notification', 'show', 'Fixture'], {}, 0, ''
    yield ['notification', 'show', 'Fixture'], {'delivered': 0}, 1, ''


def check(binary, root):
    count = 0
    for words, fixture, status, output in cases():
        result = run_fixture(binary, root, words, fixture)
        assert result['status'] == status, (words, result)
        if output is not None:
            assert result['stdout'] == output, (words, result)
        if '--json' in words and status == 0:
            parsed = json.loads(result['stdout'])
            if words[:2] == ['plugin', 'get']:
                assert parsed['actions'] == ['run']
            if words[:2] == ['plugin', 'list']:
                assert len(parsed) == 2
        count += 1
    return count


def check_validation(binary, root):
    env = environment(root)
    samples = [(['sidebar','get'], 'MissingClientId'), (['client','get','+7'], 'InvalidClientId'), (['sidebar','resize','65536'], 'InvalidWidth'), (['layout','apply'], 'MissingLayoutToken'), (['config','show','--client','7','--index','65536'], 'InvalidIndex'), (['command','suggest','0','test'], 'InvalidIdentity'), (['client','clipboard','copy','test','--client','7','--json','--json'], 'UnknownClientCommandOption')]
    for words, error in samples:
        result = subprocess.run([str(binary),*words],env=env,capture_output=True,timeout=10)
        assert result.returncode == 1 and not result.stdout and result.stderr.startswith(('telar: '+error+'; see `telar ').encode()), (words,result)
    config = root/'config.lua'
    for source, status, diagnostic in [('return {api_version=2}',0,b'telar config: OK\n'), ('local t=require("telar");return {api_version=2,client={keybindings={t.bind({"x"},"detach"),t.bind({"x"},"detach")}}}',1,b'DuplicateBinding'), ('return {api_version=2,client={keybindings={telar.bind({"x"},{kind="plugin",plugin="missing",action="run"})}}}',1,b'PluginNotConfigured')]:
        config.write_text(source)
        result=subprocess.run([str(binary),'config','check',str(config)],env=env,capture_output=True,timeout=10)
        assert result.returncode==status and diagnostic in (result.stdout if status==0 else result.stderr),result
    return len(samples)+3


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telar', type=Path, required=True)
    parser.add_argument('--scratch', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='window-', dir=args.scratch) as directory:
        print(f'{check(args.telar.resolve(), Path(directory)) + check_validation(args.telar.resolve(), Path(directory))} window CLI cases passed')


if __name__ == '__main__':
    main()
