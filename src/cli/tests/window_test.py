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
            if frame[0] == 0x33:
                entries = [] if fixture.get('empty') else [struct.pack('<QQQHQQ', 7, 11, 19, 2, 23, 29)]
                if fixture.get('second'):
                    entries.append(struct.pack('<QQQHQQ', 8, 13, 20, 0, 24, 31))
                send(connection, b'\xad' + request + bytes([len(entries)]) + b''.join(entries))
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
                        # One entry a page: the manifest, then each action.
                        actions = fixture.get('actions', ['run'])
                        items = [{'path': 'fixture', 'id': 'test', 'capabilities': []}] if value == 0 else [actions[value - 1]]
                    result = json.dumps({'generation': fixture.get('generation', 3), 'entries': items}, separators=(',', ':'))
                    result_value = 1 if value == 0 else value + 1 if action == 30 and value < len(fixture.get('actions', ['run'])) else -1
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
        result = subprocess.run([str(binary), *words, '--socket', str(path)], env=environment(root) | fixture.get('env', {}), input=b'', capture_output=True, timeout=fixture.get('timeout',10))
        future.result(timeout=fixture.get('timeout',10))
    return {'status': result.returncode, 'stdout': result.stdout.decode(), 'stderr': result.stderr.decode(), 'frames': frames}


def cases():
    """Each case: the words, the peer's fixture, the exit status, the stdout or None, and the
    `ClientCommand` a routed command sends as (action, target_id, value), None where the
    words leave a field unset."""
    for words, expected in [(['client', 'list'], 'CLIENT\tGENERATION\tIDENTITY\tATTACHMENTS\tLAST INPUT PANE\n7\t11\t19\t2\t23\n'), (['client', 'get', '7'], '7\t11\t19\t2\t23\n'), (['client', 'detach', '7'], 'client 7 detached\n')]:
        yield words, {}, 0, expected, None
        yield words + ['--json'], {}, 0, None, None
    yield ['client', 'get', '8'], {}, 2, '', None
    yield ['client', 'list', '--json'], {'empty': True}, 0, '[]\n', None
    yield ['client', 'list', '--json'], {'second': True}, 0, None, None
    actions = [(['sidebar', 'get'], 12), (['sidebar', 'show'], 13), (['sidebar', 'hide'], 14), (['sidebar', 'resize', '48'], 15), (['workspace-list', 'expand'], 16), (['workspace-list', 'collapse'], 17), (['client', 'open', 'goto'], 18), (['client', 'open', 'history'], 19), (['client', 'copy-mode'], 20), (['notification', 'dismiss', '9'], 21), (['client', 'open-link', 'https://example.invalid'], 22), (['client', 'clipboard', 'copy', 'fixture'], 23), (['layout', 'get'], 25), (['layout', 'apply', 'token'], 26), (['config', 'reload'], 27), (['config', 'show'], 28), (['plugin', 'list'], 29), (['plugin', 'get', 'test'], 30), (['plugin', 'enable', 'test'], 31), (['plugin', 'disable', 'test'], 32), (['plugin', 'run', 'test', 'run'], 33)]
    targets = {15: (None, 48), 21: (9, None)}
    for words, action in actions:
        fixture = {'text': 'visible', 'value': 48} if action == 12 else {'text': '{"escaped":"a\\b\\f\\u007f","list":[1,true,null]}'} if action == 28 else {}
        route = (action, *targets.get(action, (None, None)))
        for flags in ([], ['--json']):
            yield words + ['--client', '7'] + flags, fixture, 0, None, route
        yield words + ['--client', '7'], {'empty': True}, 2, '', None
        yield words + ['--client', '7'], {'status': 3, 'text': 'FixtureRefusal'}, 1, '', None
    yield ['pane', 'split', '5', 'vertical', '--client', '7'], {}, 0, None, (6, 5, None)
    yield ['pane', 'scroll', '5', '-3', '--client', '7'], {}, 0, None, (11, 5, -3)
    yield ['pane', 'close', '5', '--client', '7'], {}, 0, None, (7, 5, None)
    yield ['config','show','--client','7','--json'], {'text':'{"x":1.0,"y":1e2,"z":1e-20,"a":1e300,"b":-0.0,"c":1e999,"d":1e-999}'}, 0, '{"x":1,"y":100,"z":0.'+'0'*19+'1,"a":1'+'0'*300+',"b":-0,"c":1e999,"d":0}\n', None
    yield ['sidebar', 'get', '--client', '7'], {'bad_route': True}, 1, '', None
    yield ['plugin', 'list', '--client', '7'], {'generation': 0}, 1, '', None
    for status in range(4):
        yield ['command', 'suggest', '23', 'list files', '--json'], {'suggestion': status, 'text': 'ls' if status == 0 else ''}, 3 if status == 2 else 0 if status == 0 else 1, None, None
    yield ['plugin', 'get', 'test', '--client', '7', '--json'], {'actions': ['a', 'b']}, 0, None, None
    # Without --json a person reads the suggestion alone, and nothing when there is none.
    yield ['command', 'suggest', '23', 'list files'], {'suggestion': 0, 'text': 'ls'}, 0, 'ls\n', None
    yield ['command', 'suggest', '23', 'list files'], {'suggestion': 1, 'text': ''}, 1, '', None
    yield ['client', 'clipboard', 'copy', 'x'*4097, '--client', '7'], {}, 1, '', None
    yield ['sidebar', 'hide', '--client', '7', '--json'], {'text': 'a\b\f\x7fé', 'value': -9223372036854775808}, 0, None, None
    yield ['notification', 'show', 'bad\ntext'], {}, 1, '', None
    yield ['notification', 'show', 'Fixture', '--link', 'http://invalid'], {}, 1, '', None
    yield ['notification','show','Fixture','--body','é'*300], {}, 1, '', None
    yield ['notification', 'show', 'Fixture'], {}, 0, '', None
    yield ['notification', 'show', 'Fixture'], {'delivered': 0}, 1, '', None


def check(binary, root):
    count = 0
    for words, fixture, status, output, route in cases():
        result = run_fixture(binary, root, words, fixture)
        assert result['status'] == status, (words, result)
        if route:
            # The window acts on the action byte, so the CLI's word for it must name the same one.
            commands = [frame for frame in map(bytes.fromhex, result['frames']) if frame[0] == 0x35]
            action, target, value = route
            assert commands and all(frame[25] == action for frame in commands), (words, result['frames'])
            assert all(struct.unpack('<QQ', frame[9:25]) == (7, 11) for frame in commands), (words, result['frames'])
            sent_target, sent_value = struct.unpack('<Qq', commands[0][27:43])
            assert target is None or sent_target == target, (words, sent_target)
            assert value is None or sent_value == value, (words, sent_value)
        if output is not None:
            assert result['stdout'] == output, (words, result)
        if '--json' in words and status == 0:
            parsed = json.loads(result['stdout'])
            if words[:2] == ['plugin', 'get']:
                assert parsed['actions'] == fixture.get('actions', ['run']), parsed
            if words[:2] == ['plugin', 'list']:
                assert len(parsed) == 2
            if words[:2] == ['client', 'list'] and fixture.get('second'):
                assert [entry['id'] for entry in parsed] == [7, 8], parsed
        count += 1
    return count


def check_frames(binary, root):
    """What reaches the window for a notification cut at its bound, and for `command suggest --current`."""
    title = 'a' * 95 + 'é'
    result = run_fixture(binary, root, ['notification', 'show', title], {})
    shown = [frame for frame in map(bytes.fromhex, result['frames']) if frame[0] == 0x19]
    assert len(shown) == 1, result
    start = shown[0].index(b'a' * 95)
    sent = shown[0][start:start + struct.unpack('<H', shown[0][start - 2:start])[0]]
    assert len(sent) <= 96 and title.encode().startswith(sent) and sent.decode() == 'a' * 95, sent

    result = run_fixture(binary, root, ['command', 'suggest', '--current', 'list files'], {'text': 'ls', 'env': {'TELAR_PANE_ID': '23'}})
    suggested = [frame for frame in map(bytes.fromhex, result['frames']) if frame[0] == 0x29]
    assert result['status'] == 0 and len(suggested) == 1 and struct.unpack('<Q', suggested[0][9:17])[0] == 23, result
    missing = subprocess.run([str(binary), 'command', 'suggest', '--current', 'list files', '--socket', str(root / 'absent.sock')],
                             env=environment(root), capture_output=True, timeout=10)
    assert missing.returncode == 1 and not missing.stdout, missing
    return 3


def check_configuration(binary, root):
    """`config check` validates the keymap the runtime would build, under the profile and prefix it would use."""
    env = environment(root)
    package = root / 'plugin-package'
    package.mkdir(mode=0o700, exist_ok=True)
    source = Path(__file__).resolve().parents[3] / 'examples/plugins/sample'
    for name in ('plugin.json', 'plugin.lua'):
        (package / name).write_bytes((source / name).read_bytes())
        (package / name).chmod(0o600)
    duplicate = 't.bind({"x"},"detach"),t.bind({"x"},"detach")'
    plugin = 'plugins={t.plugin({path=%s})},' % json.dumps(str(package))
    cases = [
        # A profile's keybindings replace the base's: the check follows --profile.
        ('profiles={work={client={keybindings={%s}}}}' % duplicate, ['--profile', 'work'], 1, b'DuplicateBinding'),
        ('profiles={work={client={keybindings={%s}}}}' % duplicate, [], 0, b'telar config: OK'),
        ('client={keybindings={t.bind({"x"},"detach"),t.bind({"x","y"},"detach")}}', [], 1, b'AmbiguousBindingPrefix'),
        # A prefixed binding starts with the configured prefix, not the default one.
        ('client={prefix="ctrl+a",keybindings={t.bind({"x"},"detach"),t.bind_global({"ctrl+a","x"},"detach")}}', [], 1, b'DuplicateBinding'),
        ('client={prefix="ctrl+b",keybindings={t.bind({"x"},"detach"),t.bind_global({"ctrl+a","x"},"detach")}}', [], 0, b'telar config: OK'),
        (plugin + 'client={keybindings={t.bind({"o"},t.action.plugin({plugin="dev.telar.sample",action="toggle"}))}}', [], 0, b'telar config: OK'),
        (plugin + 'client={keybindings={t.bind({"o"},t.action.plugin({plugin="dev.telar.sample",action="nope"}))}}', [], 1, b'UnknownPluginAction'),
    ]
    config = root / 'checked.lua'
    for fields, options, status, diagnostic in cases:
        config.write_text('local t=require("telar");return {api_version=2,%s}' % fields)
        result = subprocess.run([str(binary), 'config', 'check', str(config), *options], env=env, capture_output=True, timeout=10)
        assert result.returncode == status and diagnostic in (result.stdout if status == 0 else result.stderr), (fields, options, result)
    for source, error in (('return {api_version=2', b'LuaLoadFailed'), ('error("x")', b'LuaRuntimeFailed')):
        config.write_text(source)
        result = subprocess.run([str(binary), 'config', 'check', str(config)], env=env, capture_output=True, timeout=10)
        assert result.returncode == 1 and error in result.stderr, (source, result)
    # Without a path, the check reads the user's config under XDG_CONFIG_HOME.
    default = Path(env['XDG_CONFIG_HOME']) / 'telar/config.lua'
    default.parent.mkdir(parents=True, exist_ok=True)
    default.write_text('local t=require("telar");return {api_version=2,client={keybindings={%s}}}' % duplicate)
    result = subprocess.run([str(binary), 'config', 'check'], env=env, capture_output=True, timeout=10)
    assert result.returncode == 1 and b'DuplicateBinding' in result.stderr, result
    default.unlink()
    return len(cases) + 3


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
        binary, root = args.telar.resolve(), Path(directory)
        count = check(binary, root) + check_frames(binary, root) + check_validation(binary, root) + check_configuration(binary, root)
        print(f'{count} window CLI cases passed')


if __name__ == '__main__':
    main()
