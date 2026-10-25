#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import struct
import subprocess
import tempfile
import time

import check_plugin_data as data


def package(root, name, identity=None, capabilities=None):
    directory = root / name
    directory.mkdir()
    manifest = data.manifest()
    manifest['id'] = identity or name
    manifest['capabilities'] = capabilities if capabilities is not None else ['proxy.tap', 'notifications']
    (directory / 'plugin.json').write_bytes(data.encoded(manifest))
    (directory / 'main.lua').write_text('return {on_exchange=function() return nil end}')
    return directory


def grant(directory, capabilities=None):
    digest = hashlib.sha256(b'telar-plugin-package-v1\0')
    for path in sorted(directory.iterdir()):
        name = path.name.encode()
        contents = path.read_bytes()
        digest.update(struct.pack('<Q', len(name)) + name + struct.pack('<Q', len(contents)) + contents)
    manifest = json.loads((directory / 'plugin.json').read_text())
    return {'plugin': manifest['id'], 'digest': digest.hexdigest(),
            'capabilities': capabilities if capabilities is not None else ['proxy.tap', 'notifications']}


def prepare(root, scenario):
    directory = package(root, 'sample')
    configured = ['{path="sample"}']
    grants = []
    trust = root / 'config/telar/trust.json'
    trust.parent.mkdir(parents=True)
    if scenario in ['trusted', 'stale-grant', 'undeclared-tap', 'missing-tap-grant', 'trusted-bad-lua']:
        grants = [grant(directory)]
    if scenario == 'missing':
        configured = ['{path="missing"}']
    elif scenario == 'disabled-missing':
        configured = ['{path="missing",enabled=false}']
    elif scenario == 'duplicate':
        package(root, 'duplicate', identity='sample')
        configured.append('{path="duplicate"}')
    elif scenario == 'invalid-manifest':
        (directory / 'plugin.json').write_text('{}')
    elif scenario == 'symlink-entry':
        (directory / 'main.lua').rename(directory / 'original.lua')
        (directory / 'main.lua').symlink_to('original.lua')
    elif scenario == 'stale-grant':
        grants[0]['digest'] = '00' * 32
    elif scenario == 'missing-tap-grant':
        grants[0]['capabilities'] = ['notifications']
    elif scenario == 'undeclared-tap':
        manifest = json.loads((directory / 'plugin.json').read_text())
        manifest['capabilities'] = ['notifications']
        (directory / 'plugin.json').write_bytes(data.encoded(manifest))
        grants = [grant(directory)]
    elif scenario in ['bad-lua', 'trusted-bad-lua']:
        (directory / 'main.lua').write_text('this is not Lua')
        if scenario == 'trusted-bad-lua':
            grants = [grant(directory)]
    elif scenario == 'empty-config-bad-trust':
        configured = []
    elif scenario.startswith('workers-') or scenario == 'configured-32':
        count = int(scenario.split('-')[1])
        configured = []
        for index in range(count):
            name = f'plugin-{index}'
            current = package(root, name)
            configured.append('{path=' + json.dumps(name) + '}')
            if scenario.startswith('workers-'):
                grants.append(grant(current))
    trust.write_bytes(data.encoded({'version': 1, 'grants': grants}))
    trust.chmod(0o600)
    if scenario in ['bad-trust', 'empty-config-bad-trust', 'no-config-bad-trust']:
        trust.write_text('invalid')
    elif scenario == 'public-trust':
        trust.chmod(0o644)
    elif scenario == 'symlink-trust':
        target = trust.with_name('original.json')
        trust.rename(target)
        trust.symlink_to(target.name)
    elif scenario == 'missing-trust':
        trust.unlink()
    configuration = root / 'config.lua'
    configuration.write_text('return {api_version=2,runtime={session={persist=false},proxy={enabled=false}},plugins={' + ','.join(configured) + '}}')
    return configuration


def run(binary, language, scenario):
    with tempfile.TemporaryDirectory(prefix='telar-plugin-startup-', dir='/tmp') as temporary:
        root = pathlib.Path(temporary).resolve()
        configuration = prepare(root, scenario)
        socket = root / 'runtime.sock'
        environment = {name: value for name, value in os.environ.items() if not name.startswith('TELAR_')}
        environment.update({'HOME': str(root / 'home'), 'XDG_CONFIG_HOME': str(root / 'config'),
                            'XDG_DATA_HOME': str(root / 'data'), 'XDG_STATE_HOME': str(root / 'state'),
                            'XDG_CACHE_HOME': str(root / 'cache'), 'SHELL': '/bin/sh'})
        (root / 'home').mkdir()
        command = [str(binary)] + (['server'] if language == 'zig' else []) + ['--socket', str(socket)]
        command += ['--no-config'] if scenario == 'no-config-bad-trust' else ['--config', str(configuration)]
        with (root / 'runtime.log').open('w+') as log:
            process = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
            started = False
            timed_out = False
            try:
                deadline = time.monotonic() + 15
                while process.poll() is None:
                    if socket.exists():
                        started = True
                        break
                    if time.monotonic() >= deadline:
                        timed_out = True
                        break
                    time.sleep(0.01)
            finally:
                if process.poll() is None and started:
                    subprocess.run([str(binary), 'server', 'stop', '--socket', str(socket)],
                                   env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                elif process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    timed_out = True
            log.seek(0)
            return {'started': started, 'timed_out': timed_out, 'exit_code': process.returncode, 'log': log.read()}


def main():
    parser = argparse.ArgumentParser(description='Compare configured plugin admission at runtime startup')
    parser.add_argument('--zig', type=pathlib.Path, required=True)
    parser.add_argument('--cpp', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    binaries = {'zig': arguments.zig.resolve(), 'cpp': arguments.cpp.resolve()}
    report = {'binaries': {name: {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                           for name, path in binaries.items()}, 'cases': []}
    scenarios = ['untrusted', 'trusted', 'missing', 'disabled-missing', 'duplicate', 'invalid-manifest',
                 'symlink-entry', 'stale-grant', 'missing-tap-grant', 'undeclared-tap', 'bad-lua',
                 'trusted-bad-lua', 'bad-trust', 'empty-config-bad-trust', 'public-trust',
                 'symlink-trust', 'missing-trust', 'no-config-bad-trust', 'workers-16', 'workers-17', 'configured-32']
    for scenario in scenarios:
        results = {language: run(binary, language, scenario) for language, binary in binaries.items()}
        equivalent = results['zig']['started'] == results['cpp']['started'] and not any(result['timed_out'] for result in results.values())
        report['cases'].append({'name': scenario, 'equivalent': equivalent, 'results': results})
        arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    report['differences'] = sum(not case['equivalent'] for case in report['cases'])
    arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f"{len(report['cases'])} startup cases, {report['differences']} differences")
    return int(bool(report['differences']))


if __name__ == '__main__':
    raise SystemExit(main())
