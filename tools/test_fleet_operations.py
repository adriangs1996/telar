#!/usr/bin/env python3
"""Isolated runtime and fake-SSH acceptance. No network or real fleet access.
Run after building: python3 tools/test_fleet_operations.py
"""
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/telar'


class FleetOperationsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tfo-', dir='/tmp')
        self.root = Path(self.temporary.name).resolve()
        for name in ('local', 'remote', 'bin', 'remote/bin', 'lt', 'rt', 'source'):
            (self.root / name).mkdir(parents=True, exist_ok=True, mode=0o700)
        (self.root / 'remote/bin/telar').symlink_to(BINARY)
        self.remote = {
            'HOME': str(self.root / 'remote'), 'TMPDIR': str(self.root / 'rt'),
            'PATH': str(self.root / 'remote/bin') + ':/usr/bin:/bin',
            'SHELL': '/bin/sh', 'USER': 'fixture', 'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_CONFIG_GLOBAL': '/dev/null',
        }
        self.local = dict(self.remote, HOME=str(self.root / 'local'), TMPDIR=str(self.root / 'lt'),
                          PATH=str(self.root / 'bin') + ':/usr/bin:/bin', GIT_SSH_VARIANT='ssh')
        fake = self.root / 'bin/ssh'
        fake.write_text('#!' + sys.executable + '\nimport os,sys\na=sys.argv[1:]\n'
                        'while a and a[0].startswith("-"):\n'
                        ' x=a.pop(0)\n'
                        ' if x in ("-o","-p","-l","-F"): a.pop(0)\n'
                        ' if x=="--": break\n'
                        'assert a.pop(0)=="fixture@fake"\n'
                        'os.execve("/bin/sh",["sh","-c"," ".join(a)],' + repr(self.remote) + ')\n')
        fake.chmod(0o755)
        self.cli('machine', 'add', 'box', 'fixture@fake')

    def tearDown(self):
        for environment in (self.remote, self.local):
            subprocess.run([str(BINARY), 'server', 'stop'], env=environment,
                           capture_output=True, timeout=20)
        deadline = time.monotonic() + 20
        while (list((self.root / 'lt').glob('telar-*/*.sock')) or list((self.root / 'rt').glob('telar-*/*.sock'))) and time.monotonic() < deadline:
            time.sleep(.05)
        deadline = time.monotonic() + 5
        while self.runtime_pids() and time.monotonic() < deadline:
            time.sleep(.05)
        # A failed fixture can leave a daemon after its socket disappears.
        # Only processes naming this exact disposable root may be terminated.
        owned = []
        for pid in self.runtime_pids():
            try:
                os.kill(pid, signal.SIGTERM)
                owned.append(pid)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 5
        while owned and time.monotonic() < deadline:
            remaining = []
            for pid in owned:
                try:
                    os.kill(pid, 0)
                    remaining.append(pid)
                except ProcessLookupError:
                    pass
            owned = remaining
            if owned:
                time.sleep(.05)
        current = set(self.runtime_pids())
        for pid in owned:
            if pid in current:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.temporary.cleanup()

    def runtime_pids(self):
        processes = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True, check=True).stdout
        owned = []
        for line in processes.splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) == 2 and fields[1].startswith(str(BINARY) + ' server ') and '--socket ' + str(self.root) + '/' in fields[1]:
                owned.append(int(fields[0]))
        return owned

    def cli(self, *args, remote=False, check=True, data=None, timeout=30):
        result = subprocess.run([str(BINARY), *map(str, args)], env=self.remote if remote else self.local,
                                cwd=self.root / 'source', input=data, capture_output=True, timeout=timeout)
        if check:
            self.assertEqual(0, result.returncode, (args, result.stdout, result.stderr))
        return result

    def git(self, *args, path=None):
        result = subprocess.run(['git', '-C', str(path or self.root / 'source'), *map(str, args)],
                                env=self.local, capture_output=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stderr)
        return result.stdout.decode().strip()

    def source(self, recipe=None):
        self.git('init')
        (self.root / 'source/readme').write_text('private history\n')
        if recipe:
            (self.root / 'source/.telar').mkdir()
            (self.root / 'source/.telar/setup.json').write_text(json.dumps({'version': 1, 'argv': recipe}))
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=f@example.invalid', 'commit', '-m', 'Initial')
        self.git('remote', 'add', 'origin', 'https://PLANTED_TOKEN@private.invalid/team/repo.git')
        return self.git('rev-parse', 'HEAD')

    def wait(self, identity, remote=False):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            value = json.loads(self.cli('exec', 'status', identity, remote=remote).stdout)
            if value['state'] in ('exited', 'failed'):
                return value
            time.sleep(.03)
        self.fail('execution did not finish')

    def test_raw_binary_literal_argv_and_exact_status_without_repository(self):
        payload = bytes(range(256)) * 128
        result = self.cli('--machine', 'box', 'exec', '--', '/bin/sh', '-c',
                          'cat; printf "%s" "$1" >&2; exit 7', 'sh', '$(touch nope); literal',
                          data=payload, check=False)
        self.assertEqual(7, result.returncode)
        self.assertEqual(payload, result.stdout)
        self.assertEqual(b'$(touch nope); literal', result.stderr)
        self.assertEqual([], json.loads(self.cli('workspace', 'list', '--json', remote=True).stdout))
        self.assertFalse((self.root / 'remote/nope').exists())

    def test_detached_eof_identity_replay_and_result_after_workspace_removal(self):
        args = ('exec', '--id', '123456', '--detach', '--', '/bin/sh', '-c', 'cat; printf done; exit 23')
        first = json.loads(self.cli(*args).stdout)
        self.assertEqual(first['execution_id'], 123456)
        self.assertEqual(23, self.wait(123456)['exit_code'])
        self.assertEqual('exited', json.loads(self.cli(*args).stdout)['state'])
        self.assertEqual(b'done', self.cli('exec', 'output', 123456).stdout)
        self.assertNotEqual(0, self.cli('exec', '--id', 123456, '--detach', '--', '/usr/bin/true', check=False).returncode)
        self.cli('exec', 'forget', 123456)
        self.assertNotEqual(0, self.cli('exec', 'status', 123456, check=False).returncode)

    def test_disconnect_timeout_and_cancel_are_distinct(self):
        process = subprocess.Popen([str(BINARY), 'exec', '--id', '234567', '--', '/bin/sh', '-c',
                                    'cat; sleep .2; printf survived'], env=self.local,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(.4)
        process.kill()
        process.communicate(timeout=5)
        self.assertEqual(0, self.wait(234567)['exit_code'])
        self.assertEqual(b'survived', self.cli('exec', 'output', 234567).stdout)
        result = self.cli('exec', '--id', 234568, '--timeout', 1, '--no-stdin', '--', '/bin/sleep', 30, check=False)
        self.assertEqual(124, result.returncode)
        self.assertIn(json.loads(self.cli('exec', 'status', 234568).stdout)['state'], ('running', 'starting'))
        self.cli('exec', 'cancel', 234568)
        self.assertEqual(137, self.wait(234568)['exit_code'])
        self.assertEqual(b'survived', self.cli('exec', 'output', 234567).stdout)

    def test_output_retention_is_bounded_and_loss_is_explicit(self):
        value = json.loads(self.cli('exec', '--detach', '--', '/bin/sh', '-c',
                                    'head -c 2097152 /dev/zero; printf separate >&2').stdout)
        status = self.wait(value['execution_id'])
        self.assertEqual(2097152, status['stdout_bytes'])
        self.assertEqual(1048576, status['stdout_offset'])
        self.assertNotEqual(0, self.cli('exec', 'output', value['execution_id'], check=False).returncode)
        output = self.cli('exec', 'output', value['execution_id'], '--stdout-offset', 1048576)
        self.assertEqual(bytes(1048576), output.stdout)
        self.assertEqual(b'separate', output.stderr)
        self.cli('exec', 'forget', value['execution_id'])

    def test_file_transfer_is_atomic_binary_and_refuses_paths(self):
        destination = self.root / 'remote/brief.bin'
        payload = bytes(range(256)) * 256
        args = ('--machine', 'box', 'exec', '--', str(BINARY), 'file', 'put', destination, '--bytes', len(payload))
        self.cli(*args, data=payload)
        self.assertEqual(payload, destination.read_bytes())
        self.assertEqual(payload, self.cli('--machine', 'box', 'exec', '--no-stdin', '--', str(BINARY), 'file', 'get', destination).stdout)
        artifact = self.root / 'remote/large-artifact'
        large = bytes(range(256)) * 16384
        artifact.write_bytes(large)
        self.assertEqual(large, self.cli('--machine', 'box', 'file', 'get', artifact).stdout)
        self.assertNotEqual(0, self.cli(*args, data=b'partial', check=False).returncode)
        self.assertEqual(payload, destination.read_bytes())
        absent = self.root / 'remote/partial'
        self.assertNotEqual(0, self.cli('file', 'put', absent, '--bytes', 50, data=b'short', check=False).returncode)
        self.assertFalse(absent.exists())
        (self.root / 'remote/link').symlink_to(self.root / 'local', target_is_directory=True)
        self.assertNotEqual(0, self.cli('file', 'put', self.root / 'remote/link/nope', '--bytes', 1, data=b'x', check=False).returncode)

    def test_prepare_setup_brief_agent_commit_fetch_and_cleanup(self):
        commit = self.source(['/bin/sh', '-c', 'printf prepared > setup-result'])
        (self.root / 'source/dirty').write_text('not transferred')
        result = self.cli('repository', 'prepare', '--machine', 'box', '--json', timeout=60)
        self.assertIn(b'1 uncommitted files', result.stderr)
        prepared = json.loads(result.stdout)
        self.assertEqual(commit, prepared['commit'])
        self.assertEqual('private.invalid/team/repo', prepared['repository'])
        self.assertEqual('not_run', prepared['environment'])
        self.assertFalse(prepared['reused'])
        clone = Path(prepared['path'])
        self.assertEqual(commit, self.git('rev-parse', 'HEAD', path=clone))
        self.assertFalse((clone / 'dirty').exists())
        self.assertNotIn('PLANTED_TOKEN', (clone / '.git/config').read_text())
        self.assertFalse((self.root / 'remote/.git-credentials').exists())
        brief = self.root / 'remote/task.md'
        self.cli('--machine', 'box', 'exec', '--', str(BINARY), 'file', 'put', brief, '--bytes', 10, data=b'task brief')
        fake_agent = self.root / 'remote/bin/codex'
        fake_agent.write_text('#!/bin/sh\n[ "$1" = --no-daemon ] || exit 9\n'
                              'test -f setup-result || exit 8\n'
                              'cat "$2" > task-result\n'
                              'git add setup-result task-result\n'
                              'git -c user.name=Fixture -c user.email=f@example.invalid commit -m Result\n')
        fake_agent.chmod(0o755)
        created = json.loads(self.cli('worktree', 'create', 'task-one', '--machine', 'box', '--title', 'Task one',
                                      '--setup', '--json', '--', 'codex', '--no-daemon', brief, timeout=60).stdout)
        deadline = time.monotonic() + 15
        while self.git('rev-parse', 'task-one', path=clone) == commit and time.monotonic() < deadline:
            time.sleep(.1)
        fetched = json.loads(self.cli('worktree', 'fetch', 'task-one', '--machine', 'box', '--json').stdout)
        self.assertNotEqual(commit, fetched['commit'])
        self.assertEqual('task brief', self.git('show', 'refs/remotes/box/task-one:task-result'))
        # No terminal is available to confirm unmerged work: merge in the
        # disposable destination clone first, then remove through Telar.
        self.git('merge', '--ff-only', 'task-one', path=clone)
        self.cli('--machine', 'box', 'worktree', 'remove', 'task-one', '--delete-branch', '--json')
        self.assertFalse(Path(created['path']).exists())
        again = self.cli('repository', 'prepare', '--machine', 'box', '--json', timeout=60)
        self.assertEqual(str(clone), json.loads(again.stdout)['path'])
        self.assertTrue(json.loads(again.stdout)['reused'])

    def test_concurrent_preparation_reuses_one_clone_and_preserves_unrelated_paths(self):
        self.source()
        command = [str(BINARY), 'repository', 'prepare', '--machine', 'box', '--json']
        children = [subprocess.Popen(command, env=self.local, cwd=self.root / 'source', stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
        paths = []
        results = []
        try:
            for child in children:
                stdout, stderr = child.communicate(timeout=60)
                results.append((child.returncode, stdout, stderr))
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                    child.communicate(timeout=10)
        for status, stdout, stderr in results:
            self.assertEqual(0, status, stderr)
            paths.append(json.loads(stdout)['path'])
        deadline = time.monotonic() + 5
        while len(self.runtime_pids()) != 1 and time.monotonic() < deadline:
            time.sleep(.05)
        self.assertEqual(1, len(self.runtime_pids()), 'concurrent cold start left another runtime')
        self.assertEqual(paths[0], paths[1])
        clone = Path(paths[0])
        self.assertEqual([clone], [p for p in clone.parent.iterdir() if p.is_dir()])
        unrelated = self.root / 'remote/unrelated'
        unrelated.mkdir()
        (unrelated / 'precious').write_text('keep')
        refused = self.cli('repository', 'prepare', '--machine', 'box', '--workspace', unrelated, check=False)
        self.assertNotEqual(0, refused.returncode)
        self.assertEqual('keep', (unrelated / 'precious').read_text())

    def test_closed_workspace_discovery_and_ambiguous_clones(self):
        self.source()
        first = self.root / 'remote/first'
        second = self.root / 'remote/second'
        for clone in (first, second):
            self.git('clone', '--no-hardlinks', self.root / 'source', clone, path=self.root)
            self.git('remote', 'set-url', 'origin', 'ssh://git@private.invalid/team/repo.git', path=clone)
        created = json.loads(self.cli('workspace', 'create', '--directory', first, '--name', 'Owned', '--json', '--', '/bin/sleep', '60', remote=True).stdout)
        self.cli('tab', 'close', created['tab_id'], '--workspace', created['workspace_id'], '--json', remote=True)
        result = self.cli('repository', 'prepare', '--machine', 'box', '--json', timeout=60)
        self.assertEqual(str(first), json.loads(result.stdout)['path'])
        self.cli('workspace', 'create', '--directory', second, '--name', 'Second', '--json', '--', '/bin/sleep', '60', remote=True)
        result = self.cli('repository', 'prepare', '--machine', 'box', '--json', check=False, timeout=60)
        self.assertNotEqual(0, result.returncode)
        self.assertIn(b'AmbiguousRepository', result.stderr)
        selected = self.cli('repository', 'prepare', '--machine', 'box', '--workspace', second, '--json', timeout=60)
        self.assertEqual(str(second), json.loads(selected.stdout)['path'])

    def test_interrupted_bundle_and_owned_stage_recovery(self):
        commit = self.source()
        ref = 'refs/telar/transfer/fixture'
        self.git('update-ref', ref, commit)
        bundle = self.root / 'bundle'
        self.git('bundle', 'create', bundle, ref)
        payload = bundle.read_bytes()
        args = ('exec', '--', str(BINARY), 'repository', 'receive', '--identity', 'private.invalid/team/repo',
                '--transport', 'https://private.invalid/team/repo.git', '--commit', commit, '--ref', ref, '--bytes', len(payload))
        result = self.cli(*args, remote=True, data=payload[:50], check=False)
        self.assertNotEqual(0, result.returncode)
        self.assertIn(b'RepositoryTransferInterrupted', result.stderr)
        repositories = self.root / 'remote/.local/share/telar/repositories'
        self.assertEqual([], [p for p in repositories.iterdir() if p.is_dir()])
        result = self.cli(*args, remote=True, data=payload)
        clone = Path(json.loads(result.stdout)['path'])
        stage = clone.with_name(clone.name + '.stage')
        stage.mkdir(mode=0o700)
        (stage / 'owner').write_text('private.invalid/team/repo')
        (stage / 'owner').chmod(0o600)
        (stage / 'interrupted').write_bytes(b'partial')
        self.cli(*args, remote=True, data=payload)
        self.assertFalse(stage.exists())
        stage.mkdir(mode=0o700)
        (stage / 'unrelated').write_text('preserve')
        self.assertNotEqual(0, self.cli(*args, remote=True, data=payload, check=False).returncode)
        self.assertTrue((stage / 'unrelated').exists())

    def test_diverged_branch_is_never_force_pushed(self):
        self.source()
        clone = Path(json.loads(self.cli('repository', 'prepare', '--machine', 'box', '--json').stdout)['path'])
        self.git('branch', 'conflict')
        self.git('checkout', '-b', 'conflict', path=clone)
        (clone / 'remote-change').write_text('remote')
        self.git('add', '.', path=clone)
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=f@example.invalid', 'commit', '-m', 'Remote', path=clone)
        remote_commit = self.git('rev-parse', 'HEAD', path=clone)
        self.git('checkout', '--detach', path=clone)
        failed = self.cli('worktree', 'create', 'conflict', '--machine', 'box', '--title', 'Conflict', '--json', '--', '/usr/bin/true', check=False)
        self.assertNotEqual(0, failed.returncode)
        self.assertEqual(remote_commit, self.git('rev-parse', 'conflict', path=clone))

    def test_unsupported_repository_content_refused_before_dispatch(self):
        self.source()
        attributes = self.root / 'source/.gitattributes'
        attributes.write_text('*.bin filter=lfs diff=lfs merge=lfs -text\n')
        self.git('add', '.gitattributes')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=f@example.invalid', 'commit', '-m', 'LFS')
        failed = self.cli('repository', 'prepare', '--machine', 'box', check=False)
        self.assertIn(b'LfsRepositoryUnsupported', failed.stderr)
        self.assertFalse((self.root / 'remote/.local/share/telar/repositories').exists())
        self.git('config', 'remote.origin.promisor', 'true')
        failed = self.cli('repository', 'prepare', '--machine', 'box', check=False)
        self.assertIn(b'PartialRepositoryUnsupported', failed.stderr)

    def test_administration_identity_and_stdin_backpressure_timeout(self):
        workspace = json.loads(self.cli('workspace', 'create', '--directory', self.root / 'source', '--name', 'Administration', '--json', '--', '/bin/sleep', 60).stdout)
        self.assertEqual(str(self.root / 'local').encode(), self.cli('exec', '--no-stdin', '--', '/bin/sh', '-c', 'printf %s "$PWD"').stdout)
        self.assertEqual(str(self.root / 'source').encode(), self.cli('exec', '--workspace', workspace['workspace_id'], '--no-stdin', '--', '/bin/sh', '-c', 'printf %s "$PWD"').stdout)
        self.assertEqual(1, len(json.loads(self.cli('workspace', 'list', '--json').stdout)))
        blocked = self.cli('exec', '--id', 314159, '--timeout', 1, '--', '/bin/sleep', 30, data=bytes(2 * 1024 * 1024), check=False, timeout=10)
        self.assertEqual(124, blocked.returncode)
        self.cli('exec', 'cancel', 314159)
        self.wait(314159)
        self.cli('tab', 'get', workspace['tab_id'], '--workspace', workspace['workspace_id'], '--json')

    def test_automatic_missing_clone_setup_gate_and_failure_prevent_agent(self):
        self.source(['/bin/sh', '-c', 'echo missing-private-registry >&2; exit 19'])
        marker = self.root / 'remote/agent-started'
        args = ('worktree', 'create', 'gated', '--machine', 'box', '--title', 'Gated', '--json', '--', '/bin/sh', '-c', 'touch ' + str(marker))
        failed = self.cli(*args, check=False)
        self.assertNotEqual(0, failed.returncode)
        self.assertIn(b'ProjectSetupRequiresExplicitSetupFlag', failed.stderr)
        self.assertFalse(marker.exists())
        # The clone and worktree are retained for an explicit setup retry.
        failed = self.cli('worktree', 'create', 'fails-setup', '--machine', 'box', '--title', 'Fails setup', '--setup', '--json', '--', '/bin/sh', '-c', 'touch ' + str(marker), check=False)
        self.assertNotEqual(0, failed.returncode)
        self.assertIn(b'missing-private-registry', failed.stderr)
        self.assertFalse(marker.exists())
        listed = self.cli('--machine', 'box', 'worktree', 'list', '--json')
        self.assertIn(b'fails-setup', listed.stdout)

    def test_repository_lock_and_clone_permissions_refuse_unsafe_reuse(self):
        self.source()
        clone = Path(json.loads(self.cli('repository', 'prepare', '--machine', 'box', '--json').stdout)['path'])
        lock = clone.with_name(clone.name + '.lock')
        lock.unlink()
        precious = self.root / 'remote/precious'
        precious.write_text('keep')
        precious.chmod(0o600)
        lock.symlink_to(precious)
        failed = self.cli('repository', 'prepare', '--machine', 'box', check=False)
        self.assertIn(b'UnsafeRepositoryLock', failed.stderr)
        self.assertEqual('keep', precious.read_text())
        lock.unlink()
        clone.chmod(0o777)
        failed = self.cli('repository', 'prepare', '--machine', 'box', check=False)
        self.assertIn(b'UnsafeTransferDirectory', failed.stderr)
        clone.chmod(0o700)

    def test_shallow_and_submodules_refused(self):
        commit = self.source()
        (self.root / 'source/.git/shallow').write_text(commit + '\n')
        failed = self.cli('repository', 'prepare', '--machine', 'box', check=False)
        self.assertIn(b'ShallowRepositoryUnsupported', failed.stderr)
        (self.root / 'source/.git/shallow').unlink()
        self.git('update-index', '--add', '--cacheinfo', '160000,' + commit + ',submodule')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=f@example.invalid', 'commit', '-m', 'Submodule')
        failed = self.cli('repository', 'prepare', '--machine', 'box', check=False)
        self.assertIn(b'SubmoduleRepositoryUnsupported', failed.stderr)

    def test_file_special_types_and_oversized_input_refused_without_waiting(self):
        fifo = self.root / 'remote/fifo'
        os.mkfifo(fifo)
        self.assertNotEqual(0, self.cli('file', 'get', fifo, check=False, timeout=5).returncode)
        original = self.root / 'remote/original'
        original.write_bytes(b'keep')
        hardlink = self.root / 'remote/hardlink'
        os.link(original, hardlink)
        self.assertNotEqual(0, self.cli('file', 'get', hardlink, check=False).returncode)
        self.assertNotEqual(0, self.cli('file', 'put', self.root / 'remote/../escaped', '--bytes', 1, data=b'x', check=False).returncode)
        self.assertNotEqual(0, self.cli('file', 'put', self.root / 'remote/huge', '--bytes', 128 * 1024 * 1024 + 1, data=b'', check=False).returncode)
        self.assertFalse((self.root / 'remote/huge').exists())

    def test_execution_identity_cannot_alias_field_boundaries(self):
        first = str(self.root / 'source')
        failed = self.cli('exec', '--id', 901, '--cwd', first, '--', 'b\x01c', data=b'', check=False)
        self.assertEqual(125, failed.returncode)
        conflict = self.cli('exec', '--id', 901, '--cwd', first + '\x01b', '--', 'c', data=b'', check=False)
        self.assertIn(b'ExecutionIdentityConflict', conflict.stderr)

    def test_execution_capacity_launch_failure_and_runtime_shutdown(self):
        failed = self.cli('exec', '--id', 600, '--no-stdin', '--', '/no/such/fixture-program', check=False)
        self.assertEqual(125, failed.returncode)
        self.assertIn(b'FileNotFound', failed.stderr)
        self.assertEqual('failed', self.wait(600)['state'])
        self.cli('exec', 'forget', 600)
        for identity in range(1, 33):
            self.cli('exec', '--id', identity, '--detach', '--', '/usr/bin/true')
        self.wait(32)
        retained = json.loads(self.cli('exec', 'list', '--json').stdout)
        self.assertEqual(list(range(1, 33)), [row['execution_id'] for row in retained])
        full = self.cli('exec', '--detach', '--', '/usr/bin/true', check=False)
        self.assertIn(b'ExecutionLimitReached', full.stderr)
        self.cli('exec', 'forget', 1)
        self.assertEqual(31, len(json.loads(self.cli('exec', 'list').stdout)))
        pidfile = self.root / 'local/owned-pid'
        self.cli('exec', '--id', 77, '--detach', '--', '/bin/sh', '-c', 'echo $$ > ' + str(pidfile) + '; exec /bin/sleep 60')
        deadline = time.monotonic() + 5
        while not pidfile.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        pid = int(pidfile.read_text())
        self.cli('server', 'stop')
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(.05)
        else:
            self.fail('runtime-owned child survived orderly shutdown')

    def test_setup_failure_retry_and_cancellation(self):
        directory = self.root / 'source/.telar'
        directory.mkdir()
        recipe = directory / 'setup.json'
        recipe.write_text(json.dumps({'version': 1, 'argv': ['/bin/sh', '-c', 'test -n "$PRIVATE_REGISTRY_TOKEN" || { echo missing-registry-access >&2; exit 19; }']}))
        failed = self.cli('project', 'setup', '--cwd', self.root / 'source', check=False)
        self.assertNotEqual(0, failed.returncode)
        self.assertIn(b'missing-registry-access', failed.stderr)
        recipe.write_text(json.dumps({'version': 1, 'argv': ['/usr/bin/true']}))
        self.cli('project', 'setup', '--cwd', self.root / 'source')
        recipe.write_text(json.dumps({'version': 1, 'argv': ['/bin/sleep', '30']}))
        identity = json.loads(self.cli('project', 'setup', '--cwd', self.root / 'source', '--detach').stdout)['execution_id']
        self.cli('exec', 'cancel', identity)
        self.assertEqual(137, self.wait(identity)['exit_code'])


if __name__ == '__main__':
    unittest.main()
