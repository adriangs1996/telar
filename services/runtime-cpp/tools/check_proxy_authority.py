#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def start_zig(arguments, root, authority):
    configuration = root / 'config.lua'
    configuration.write_text('return {api_version=2,runtime={session={persist=false},proxy={enabled=true,ca_dir=' + json.dumps(str(authority)) + '}}}\n')
    endpoint = root / 'runtime.sock'
    environment = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    for name in ['CONFIG', 'DATA', 'STATE', 'CACHE']:
        environment[f'XDG_{name}_HOME'] = str(root / name.lower())
    with (root / 'server.log').open('w+') as log:
        server = subprocess.Popen([str(arguments.zig), 'server', '--socket', str(endpoint), '--config', str(configuration)], env=environment, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 15
            while not endpoint.exists():
                if server.poll() is not None or time.monotonic() >= deadline:
                    log.seek(0)
                    raise RuntimeError('Zig proxy startup failed: ' + log.read())
                time.sleep(0.01)
            ready = subprocess.run([str(arguments.runtime_probe), str(endpoint), 'limits', '1', str(root / 'ready.bin')], capture_output=True, text=True, timeout=10)
            if ready.returncode:
                raise RuntimeError('Zig did not complete protocol initialization: ' + ready.stderr)
            if not (authority / 'ca-bundle.pem').exists():
                raise RuntimeError('Zig did not initialize the private authority')
        finally:
            if server.poll() is None:
                server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
    endpoint.unlink(missing_ok=True)


def start_cpp(probe, authority):
    result = subprocess.run([str(probe), '--authority', str(authority)], capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError('C++ authority failed: ' + result.stderr)
    return result.stdout.splitlines()[0]


def verify_leaf(openssl, authority):
    result = subprocess.run([str(openssl), 'verify', '-CAfile', str(authority / 'ca-cert.pem'), str(authority / 'fixture-leaf.pem')], capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError('Certificate chain verification failed: ' + result.stderr)


def check_sequence(arguments, creator):
    with tempfile.TemporaryDirectory(prefix='telar-authority-', dir='/tmp') as temporary:
        root = Path(temporary)
        authority = root / 'authority'
        if creator == 'zig':
            start_zig(arguments, root, authority)
        else:
            start_cpp(arguments.probe, authority)
        before = {name: (authority / name).read_bytes() for name in ['ca-key.pem', 'ca-cert.pem']}
        identity = start_cpp(arguments.probe, authority)
        verify_leaf(arguments.openssl, authority)
        start_zig(arguments, root, authority)
        if identity != start_cpp(arguments.probe, authority):
            raise RuntimeError('Authority identity changed across reloads')
        verify_leaf(arguments.openssl, authority)
        for name, data in before.items():
            if (authority / name).read_bytes() != data:
                raise RuntimeError('Authority files changed during reload: ' + name)
            if (authority / name).stat().st_mode & 0o777 != 0o600:
                raise RuntimeError('Authority file permissions changed: ' + name)
        return {'creator': creator, 'fingerprint': identity, 'certificate_sha256': fingerprint(authority / 'ca-cert.pem'), 'files_unchanged': True, 'private_permissions': True, 'leaf_verified': True}


def main():
    parser = argparse.ArgumentParser(description='Cross-load private TLS authorities between independent C++ and Zig implementations')
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--runtime-probe', type=Path, required=True)
    parser.add_argument('--openssl', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    for name in ['zig', 'probe', 'runtime_probe', 'openssl']:
        setattr(arguments, name, getattr(arguments, name).resolve())
    report = {'checked_at': datetime.now(timezone.utc).isoformat(), 'binaries': {name: {'path': str(getattr(arguments, name)), 'sha256': fingerprint(getattr(arguments, name))} for name in ['zig', 'probe', 'runtime_probe', 'openssl']}, 'cases': [], 'passed': False}
    try:
        for creator in ['zig', 'cpp']:
            report['cases'].append(check_sequence(arguments, creator))
        report['passed'] = True
    except Exception as error:
        report['failure'] = str(error)
        raise
    finally:
        arguments.output.write_text(json.dumps(report, indent=2) + '\n')
    print('Both authority origins preserve their keys, certificates and verified leaf chains')


if __name__ == '__main__':
    main()
