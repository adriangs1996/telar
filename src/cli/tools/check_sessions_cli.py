#!/usr/bin/env python3
"""Exercise an isolated session CLI stack.

Only generated identities, setup execution ids and status ages are normalized.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time


def environment(root):
    env = {k: v for k, v in os.environ.items() if not k.startswith('TELAR_')}
    for key, name in [('HOME', 'h'), ('XDG_RUNTIME_DIR', 'r'), ('XDG_DATA_HOME', 'd'),
                      ('XDG_CONFIG_HOME', 'c'), ('XDG_CACHE_HOME', 'cache'), ('XDG_STATE_HOME', 'state'), ('TMPDIR', 'tmp')]:
        path = root / name
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        env[key] = str(path)
    env.update(SHELL='/bin/bash', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
               GIT_AUTHOR_NAME='Session fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
               GIT_COMMITTER_NAME='Session fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
    return env


def invoke(binary, words, env, cwd, socket=None):
    args = list(map(str, words))
    if socket is not None:
        position = args.index('--') if '--' in args else len(args)
        args[position:position] = ['--socket', str(socket)]
    result = subprocess.run([str(binary), *args], env=env, cwd=cwd, input=b'', capture_output=True, timeout=45)
    return {'status': result.returncode, 'stdout': result.stdout.decode('utf-8', 'backslashreplace'),
            'stderr': result.stderr.decode('utf-8', 'backslashreplace')}


def validation_cases():
    cases = []
    def add(args, error):
        cases.append((args, error))
    for family, noun in [('workspace', 'Workspace'), ('tab', 'Tab'), ('worktree', 'Worktree')]:
        add([family, 'bogus'], 'Unknown' + noun + 'Action')
        add([family, 'list', '--bad'], 'Unknown' + noun + 'Option')
    for verb in ('get', 'rename'):
        add(['workspace', verb], 'MissingWorkspaceTarget')
        for identity in ('0', '-1', '+1', 'bad', '_1', '1_', '18446744073709551616'):
            add(['workspace', verb, identity], 'InvalidIdentity')
    add(['workspace', 'rename', '1'], 'MissingWorkspaceName')
    for name in ('', 'x' * 257):
        add(['workspace', 'rename', '1', name], 'InvalidWorkspaceName')
    for option, missing in [('--directory', 'MissingWorktreeDirectory'), ('--name', 'MissingWorkspaceName'),
                            ('--columns', 'MissingWorkspaceColumns'), ('--worktree', 'MissingWorktreeBranch'), ('--socket', 'MissingSocketPath')]:
        add(['workspace', 'create', option], missing)
    add(['workspace', 'create'], 'MissingWorktreeBranch')
    add(['workspace', 'create', '--directory', ''], 'EmptyWorkspaceDirectory')
    for column in ('0', '19', '1025', '65536', 'bad', '-1'):
        add(['workspace', 'create', '--directory', '.', '--columns', column], 'InvalidWorkspaceColumns')
    add(['workspace', 'create', '--directory', '.', '--'], 'MissingWorkspaceCommand')
    add(['workspace', 'create', '--worktree', 'fix', '--columns', '80'], 'UnknownWorkspaceOption')
    add(['workspace', 'create', '--worktree', 'fix', '--', 'true'], 'UnknownWorkspaceOption')
    for option, duplicate in [('--directory', 'DuplicateDirectoryOption'), ('--name', 'DuplicateNameOption'),
                              ('--worktree', 'DuplicateWorktreeOption'), ('--socket', 'DuplicateSocketOption')]:
        add(['workspace', 'create', option, 'fix', option, 'fix'], duplicate)
    for verb in ('get', 'rename', 'close', 'move'):
        add(['tab', verb], 'MissingTabTarget')
        add(['tab', verb, '0'], 'InvalidIdentity')
    add(['tab', 'rename', '1'], 'MissingTabLabel')
    for label in ('', 'x' * 129):
        add(['tab', 'rename', '1', label], 'InvalidTabLabel')
    add(['tab', 'move', '1'], 'MissingMoveDirection')
    add(['tab', 'move', '1', 'left'], 'InvalidMoveDirection')
    add(['tab', 'move', '1', 'next', '--relative-to', '--current'], 'InvalidRelativeTarget')
    add(['tab', 'move', '1', 'next', '--relative-to'], 'MissingRelativeTarget')
    add(['tab', 'move', '1', 'next', '--relative-to', '2', '--relative-to', '3'], 'DuplicateRelativeTarget')
    add(['tab', 'create', '--background', '--background'], 'DuplicateBackgroundOption')
    add(['tab', 'create', '--background', '--label', 'x' * 129], 'InvalidTabLabel')
    add(['tab', 'create', '--background', '--label', 'x', '--label', 'y'], 'DuplicateLabelOption')
    for args, error in [(['--workspace'], 'MissingWorkspaceTarget'), (['--workspace', '0'], 'InvalidIdentity'),
                        (['--workspace', '1', '--workspace', '2'], 'DuplicateWorkspaceOption'),
                        (['--json', '--json'], 'DuplicateJsonOption'), (['--socket'], 'MissingSocketPath'),
                        (['--socket', 'a', '--socket', 'b'], 'DuplicateSocketOption')]:
        add(['tab', 'list', *args], error)
    for family, verb in [('workspace', 'select'), ('tab', 'select'), ('tab', 'next'), ('tab', 'previous'), ('tab', 'create')]:
        target = ['1'] if verb == 'select' else []
        if target:
            add([family, verb], 'MissingTarget')
            add([family, verb, '0'], 'InvalidTarget')
        add([family, verb, *target], 'MissingClientId')
        add([family, verb, *target, '--client'], 'MissingClientId')
        add([family, verb, *target, '--client', '0'], 'InvalidTarget')
        add([family, verb, *target, '--client', '1', '--json', '--json'], 'UnknownClientCommandOption')
        add([family, verb, *target, '--client', '1', '--socket'], 'MissingSocketPath')
    for verb in ('create', 'exec', 'open', 'diff', 'remove', 'fetch'):
        add(['worktree', verb], 'MissingWorktreeBranch')
        add(['worktree', verb, '--json'], 'MissingWorktreeBranch')
    for branch in ('', '.hidden', 'a..b', 'a b', 'x' * 201, 'a:b', 'a~b', 'a\x7f'):
        add(['worktree', 'create', branch], 'InvalidWorktreeBranch')
    add(['worktree', 'exec', 'fix'], 'MissingWorktreeCommand')
    add(['worktree', 'exec', 'fix', '--'], 'MissingWorktreeCommand')
    add(['worktree', 'create', 'fix', '--', 'true'], 'MissingWorktreeTitle')
    add(['worktree', 'exec', 'fix', '--', *(['a'] * 33)], 'TooManyCommandArguments')
    add(['worktree', 'list', '--', 'true'], 'UnexpectedWorktreeCommand')
    add(['worktree', 'fetch', 'fix'], 'MissingMachineLabel')
    add(['worktree', 'resolve'], 'MissingRepository')
    for option, missing in [('--title', 'MissingWorktreeTitle'), ('--from', 'MissingWorktreeBase'), ('--directory', 'MissingWorktreeDirectory'),
                            ('--label', 'MissingTabLabel'), ('--machine', 'MissingMachineLabel'), ('--coordinator', 'MissingCoordinatorReference'),
                            ('--workspace', 'MissingWorkspaceTarget'), ('--socket', 'MissingSocketPath')]:
        add(['worktree', 'create', 'fix', option], missing)
    add(['worktree', 'create', 'fix', '--directory', 'relative'], 'RelativeWorktreeDirectory')
    add(['worktree', 'create', 'fix', '--machine', 'box', '--directory', '/x'], 'DirectoryOnAnotherMachine')
    for value in ('', 'x' * 97, 'bad\ntext', 'bad\x7ftext'):
        add(['worktree', 'create', 'fix', '--title', value], 'InvalidWorktreeText')
    for value in ('0', '-1', 'bad', '86401'):
        add(['worktree', 'exec', 'fix', '--timeout', value, '--', 'true'], 'InvalidTimeout')
    add(['worktree', 'create', 'fix', '--coordinator', 'bad'], 'InvalidCoordinatorReference')
    add(['worktree', 'create', 'fix', '--machine', '-box'], 'InvalidMachineLabel')
    add(['worktree', 'create', 'fix', '--title', 'x', '--title', 'y'], 'DuplicateWorktreeOption')
    return cases


def validation(binary, root):
    env = environment(root)
    results = {}
    for index, (words, error) in enumerate(validation_cases()):
        result = invoke(binary, words, env, root)
        assert result['status'] == 1 and not result['stdout'] and f'telar: {error}; see `' in result['stderr'], (words, error, result)
        results[f'validation-{index:03}'] = result
    return results


class Stack:
    def __init__(self, binary, root, gui=None):
        self.binary, self.root, self.gui = binary, root, gui
        self.env = environment(root)
        self.socket = root / 's'
        self.repo = root / 'repo'
        self.repo.mkdir()
        self.results = {}
        self.runtime = None
        self.log = None
        self.window = None
        self.ids = {k: {} for k in ('workspace_id', 'source_workspace_id', 'tab_id', 'pane_id', 'worktree_id', 'client_id', 'setup_execution_id')}
        self.ids['source_workspace_id'] = self.ids['workspace_id']

    def git(self, *words, cwd=None):
        return subprocess.run(['git', '-C', str(cwd or self.repo), *map(str, words)], env=self.env, capture_output=True, check=True).stdout

    def call(self, name, *words, status=0, env=None):
        result = invoke(self.binary, words, env or self.env, self.repo, self.socket)
        if status is not None:
            assert result['status'] == status, (name, words, result)
        self.results[name] = result
        return json.loads(result['stdout']) if '--json' in words and result['stdout'] else result['stdout']

    def answer(self, name, reply, *words, status=0):
        """Runs telar with a terminal as stdin, where a person types `reply` at its prompt."""
        args = [str(self.binary), *map(str, words), '--socket', str(self.socket)]
        primary, secondary = os.openpty()
        try:
            process = subprocess.Popen(args, env=self.env, cwd=self.repo, stdin=secondary, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            os.close(secondary)
            secondary = None
            os.write(primary, reply + b'\n')
            stdout, stderr = process.communicate(timeout=45)
        finally:
            if secondary is not None:
                os.close(secondary)
            os.close(primary)
        result = {'status': process.returncode, 'stdout': stdout.decode('utf-8', 'backslashreplace'), 'stderr': stderr.decode('utf-8', 'backslashreplace')}
        assert result['status'] == status, (name, words, result)
        self.results[name] = result
        return result

    def start(self):
        self.git('init', '-b', 'main')
        (self.repo / 'file.txt').write_text('base\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'Fixture')
        self.git('remote', 'add', 'origin', 'git@EXAMPLE.invalid:team/repo.git')
        self.call('workspace-list-no-runtime', 'workspace', 'list', '--json', status=1)
        assert not self.socket.exists()
        first = self.call('workspace-autostart', 'workspace', 'create', '--directory', str(self.repo), '--json')
        self.call('workspace-autostart-close', 'tab', 'close', str(first['tab_id']), '--workspace', str(first['workspace_id']), '--json')
        invoke(self.binary, ['server', 'stop'], self.env, self.repo, self.socket)
        deadline = time.monotonic() + 15
        while self.socket.exists():
            assert time.monotonic() < deadline
            time.sleep(.02)
        self.log = (self.root / 'runtime.log').open('wb')
        self.runtime = subprocess.Popen([str(self.binary), 'server', '--socket', str(self.socket), '--no-config', '--fresh'],
                                        env=self.env, cwd=self.repo, stdout=self.log, stderr=self.log, start_new_session=True)
        deadline = time.monotonic() + 15
        while not self.socket.exists():
            if self.runtime.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError((self.root / 'runtime.log').read_text())
            time.sleep(.02)

    def stop(self):
        if self.window and self.window.poll() is None:
            os.killpg(self.window.pid, signal.SIGTERM)
            try:
                self.window.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.window.pid, signal.SIGKILL)
                self.window.wait()
        if self.socket.exists():
            invoke(self.binary, ['server', 'stop'], self.env, self.repo, self.socket)
        if self.runtime:
            if self.runtime.poll() is None:
                try:
                    invoke(self.binary, ['server', 'stop'], self.env, self.repo, self.socket)
                    self.runtime.wait(timeout=15)
                except (subprocess.TimeoutExpired, OSError):
                    os.killpg(self.runtime.pid, signal.SIGTERM)
                    self.runtime.wait(timeout=10)
            self.log.close()

    def exercise(self):
        self.start()
        assert self.call('workspace-list-empty', 'workspace', 'list', '--json') == []
        self.call('workspace-list-empty-text', 'workspace', 'list')
        created = self.call('workspace-create', 'workspace', 'create', '--directory', str(self.repo), '--name', 'Project ñ', '--columns', '100', '--json')
        wid, tid = str(created['workspace_id']), str(created['tab_id'])
        deadline = time.monotonic() + 10
        while True:
            observed = invoke(self.binary, ['workspace', 'get', wid, '--json'], self.env, self.repo, self.socket)
            if observed['status'] == 0 and json.loads(observed['stdout'])['branch'] == 'main':
                break
            assert time.monotonic() < deadline, ('workspace Git probe did not settle', observed)
            time.sleep(.05)
        self.call('workspace-list', 'workspace', 'list', '--json')
        extra = self.call('workspace-create-second', 'workspace', 'create', '--directory', str(self.repo), '--name', 'Second', '--json')
        listed = self.call('workspace-list-many', 'workspace', 'list', '--json')
        assert sorted(entry['workspace_id'] for entry in listed) == sorted([created['workspace_id'], extra['workspace_id']]), listed
        assert all(set(entry) >= {'workspace_id', 'name', 'path', 'tab_count', 'branch', 'dirty'} for entry in listed), listed
        self.call('workspace-close-second', 'tab', 'close', str(extra['tab_id']), '--workspace', str(extra['workspace_id']), '--json')
        self.call('workspace-get', 'workspace', 'get', wid, '--json')
        self.call('workspace-get-text', 'workspace', 'get', wid)
        self.call('workspace-rename', 'workspace', 'rename', wid, 'Quoted "name" ñ', '--json')
        self.call('workspace-rename-text', 'workspace', 'rename', wid, 'Project')
        self.call('workspace-get-missing', 'workspace', 'get', '999999', '--json', status=1)
        self.call('workspace-get-current-missing', 'workspace', 'get', '--current', '--json', status=1)
        current_env = dict(self.env, TELAR_WORKSPACE_ID=wid, TELAR_TAB_ID=tid)
        self.call('workspace-get-underscore-id', 'workspace', 'get', '0_' + wid, '--json')
        self.call('workspace-get-current', 'workspace', 'get', '--current', '--json', env=current_env)
        for index, name in enumerate(('x' * 129, 'bad\nname', 'bad\bname')):
            self.call(f'workspace-create-wire-invalid-{index}', 'workspace', 'create', '--directory', str(self.repo), '--name', name, status=1)
            self.call(f'workspace-rename-wire-invalid-{index}', 'workspace', 'rename', wid, name, status=1)
        self.call('tab-rename-wire-invalid', 'tab', 'rename', tid, 'bad\nlabel', '--workspace', wid, status=1)
        self.call('tab-list', 'tab', 'list', '--workspace', wid, '--json')
        self.call('tab-list-text', 'tab', 'list', '--workspace', wid)
        self.call('tab-get', 'tab', 'get', tid, '--workspace', wid, '--json')
        self.call('tab-get-text', 'tab', 'get', tid, '--workspace', wid)
        self.call('tab-get-current', 'tab', 'get', '--current', '--workspace', '--current', '--json', env=current_env)
        self.call('tab-list-current-missing', 'tab', 'list', '--json', status=1)
        second = self.call('tab-create', 'tab', 'create', '--background', '--workspace', wid, '--label', 'Tab ñ', '--json')
        second_id = str(second['tab_id'])
        self.call('tab-rename', 'tab', 'rename', second_id, 'Name "quoted"', '--workspace', wid, '--json')
        self.call('tab-rename-text', 'tab', 'rename', second_id, 'Text tab', '--workspace', wid)
        def order(name):
            return [str(entry['tab_id']) for entry in self.call(name, 'tab', 'list', '--workspace', wid, '--json')]

        assert order('tab-list-before-move') == [tid, second_id]
        moved = self.call('tab-move', 'tab', 'move', second_id, 'previous', '--workspace', wid, '--json')
        assert moved['position'] == 0 and order('tab-list-moved') == [second_id, tid], moved
        # --relative-to moves a tab next to the named one, not one position.
        third_id = str(self.call('tab-create-third', 'tab', 'create', '--background', '--workspace', wid, '--json')['tab_id'])
        relative = self.call('tab-move-before', 'tab', 'move', third_id, 'previous', '--relative-to', second_id, '--workspace', wid, '--json')
        assert relative['position'] == 0 and order('tab-list-before') == [third_id, second_id, tid], relative
        self.call('tab-close-third', 'tab', 'close', third_id, '--workspace', wid, '--json')
        self.call('tab-move-relative', 'tab', 'move', second_id, 'next', '--relative-to', tid, '--workspace', wid)
        assert order('tab-list-after-move') == [tid, second_id]
        # A tab opened from anywhere starts in its workspace's directory.
        elsewhere = invoke(self.binary, ['tab', 'create', '--background', '--workspace', wid, '--json'], self.env, self.root, self.socket)
        assert elsewhere['status'] == 0, elsewhere
        opened = json.loads(elsewhere['stdout'])
        self.call('tab-pwd', 'pane', 'send-keys', str(opened['pane_id']), 'pwd', '--enter')
        deadline = time.monotonic() + 10
        while str(self.repo) not in invoke(self.binary, ['pane', 'read', str(opened['pane_id'])], self.env, self.repo, self.socket)['stdout'].splitlines():
            assert time.monotonic() < deadline, 'the new tab did not start in the workspace directory'
            time.sleep(.05)
        self.call('tab-close-elsewhere', 'tab', 'close', str(opened['tab_id']), '--workspace', wid, '--json')
        self.call('tab-get-missing', 'tab', 'get', '999999', '--workspace', wid, '--json', status=1)
        closed = self.call('tab-close', 'tab', 'close', second_id, '--workspace', wid, '--json')
        assert closed == {'workspace_id': int(wid), 'tab_id': int(second_id), 'closed': True, 'workspace_closed': False}, closed
        self.call('workspace-select-client-missing', 'workspace', 'select', wid, '--client', '999999', '--json', status=2)
        self.call('tab-next-client-missing', 'tab', 'next', '--client', '999999', '--json', status=2)
        self.call('tab-previous-client-missing', 'tab', 'previous', '--client', '999999', status=2)
        self.call('tab-select-client-missing', 'tab', 'select', tid, '--client', '999999', status=2)
        self.call('tab-create-client-missing', 'tab', 'create', '--client', '999999', status=2)
        wt = self.call('worktree-create', 'worktree', 'create', 'fix/test', '--title', 'Fix task', '--workspace', wid, '--json')
        checkout = Path(wt['path'])
        assert checkout.is_dir()
        self.call('worktree-list-tracked', 'worktree', 'list', '--json')
        self.call('worktree-list-tracked-text', 'worktree', 'list')
        self.call('worktree-duplicate', 'worktree', 'create', 'fix/test', '--workspace', wid, status=1)
        self.call('worktree-open-client-missing', 'worktree', 'open', 'Fix task', '--json', status=1)
        self.call('worktree-exec', 'worktree', 'exec', 'Fix task', '--json', '--', '/bin/sleep', '20')
        self.call('worktree-exec-wait', 'worktree', 'exec', 'fix task', '--wait', '--json', '--', '/bin/sh', '-c', 'printf "hello literal; $x\\n"; exit 7', status=7)
        assert self.call('worktree-exec-wait-text', 'worktree', 'exec', 'fix/test', '--wait', '--', '/usr/bin/printf', 'text output\n') == 'text output\n'
        literal = self.call('worktree-exec-literal', 'worktree', 'exec', 'fix/test', '--wait', '--json', '--', '/usr/bin/printf', '%s', 'a; echo unsafe $HOME "quoted"')
        assert literal['output'] == 'a; echo unsafe $HOME "quoted"'
        self.call('worktree-exec-timeout', 'worktree', 'exec', 'fix/test', '--wait', '--timeout', '1s', '--json', '--', '/bin/sleep', '20', status=3)
        self.call('worktree-diff-empty', 'worktree', 'diff', 'fix/test')
        (checkout / 'file.txt').write_text('base\nchanged\n')
        self.call('worktree-diff', 'worktree', 'diff', 'Fix task', '--uncommitted')
        self.call('worktree-diff-stat', 'worktree', 'diff', 'fix/test', '--stat')
        self.call('worktree-remove-dirty', 'worktree', 'remove', 'fix/test', status=1)
        self.call('worktree-remove-force-no-tty', 'worktree', 'remove', 'fix/test', '--force', status=1)
        for index, reply in enumerate((b'n', b'', b'nope')):
            self.answer(f'worktree-remove-force-declined-{index}', reply, 'worktree', 'remove', 'fix/test', '--force', status=1)
            assert (checkout / 'file.txt').read_text() == 'base\nchanged\n'
        self.git('checkout', '--', 'file.txt', cwd=checkout)
        resolved = self.call('worktree-resolve', 'worktree', 'resolve', '--repository', 'example.invalid/team/repo', '--json')
        assert resolved == {'repository': 'example.invalid/team/repo', 'path': str(self.repo)}, resolved
        selected = self.call('worktree-resolve-selected', 'worktree', 'resolve', '--repository', 'example.invalid/team/repo', '--workspace', wid)
        assert selected == str(self.repo) + '\n', selected
        self.call('worktree-resolve-wrong', 'worktree', 'resolve', '--repository', 'other/repo', '--workspace', wid, status=1)
        self.call('worktree-resolve-missing', 'worktree', 'resolve', '--repository', 'other/repo', status=1)
        self.call('worktree-remove', 'worktree', 'remove', 'Fix task', '--delete-branch', '--json')
        assert not checkout.exists()
        assert not self.git('branch', '--list', 'fix/test').strip()
        other = self.call('worktree-create-unmerged', 'worktree', 'create', 'unmerged', '--json')
        other_path = Path(other['path'])
        (other_path / 'other.txt').write_text('unmerged data\n')
        self.git('add', '.', cwd=other_path)
        self.git('commit', '-qm', 'Unmerged work', cwd=other_path)
        self.call('worktree-delete-unmerged-no-tty', 'worktree', 'remove', 'unmerged', '--delete-branch', status=1)
        assert other_path.is_dir()
        self.answer('worktree-delete-unmerged-declined', b'N', 'worktree', 'remove', 'unmerged', '--delete-branch', status=1)
        assert other_path.is_dir() and self.git('branch', '--list', 'unmerged').strip()
        self.call('worktree-remove-keep-branch', 'worktree', 'remove', 'unmerged', '--json')
        assert self.git('branch', '--list', 'unmerged').strip()
        self.call('worktree-list-empty', 'worktree', 'list', '--json')
        self.call('worktree-list-empty-text', 'worktree', 'list')
        self.git('worktree', 'add', '-qb', 'manual', str(self.root / 'manual'))
        # Two tracked worktrees whose titles differ only in case, beside the untracked one.
        titled = [self.call(f'worktree-create-titled-{branch}', 'worktree', 'create', branch, '--title', title, '--json') for branch, title in (('titled-a', 'Fix'), ('titled-b', 'fix'))]
        listed = self.call('worktree-list-many', 'worktree', 'list', '--json')
        assert sorted((entry['branch'], entry['origin']) for entry in listed if entry['worktree_id'] is not None) == [('titled-a', 'telar'), ('titled-b', 'telar')], listed
        assert [(entry['branch'], entry['origin']) for entry in listed if entry['worktree_id'] is None] == [('manual', 'untracked')], listed
        self.call('worktree-remove-ambiguous-title', 'worktree', 'remove', 'fix', status=1)
        assert all(Path(entry['path']).is_dir() for entry in titled)
        self.call('worktree-remove-titled-a', 'worktree', 'remove', 'titled-a')
        self.call('worktree-remove-titled-b', 'worktree', 'remove', 'titled-b')
        # Git refuses a locked checkout although it is clean: it stays on disk and stays tracked.
        locked = Path(self.call('worktree-create-locked', 'worktree', 'create', 'locked', '--json')['path'])
        self.git('worktree', 'lock', str(locked))
        self.call('worktree-remove-locked', 'worktree', 'remove', 'locked', status=1)
        assert locked.is_dir()
        tracked = self.call('worktree-list-locked', 'worktree', 'list', '--json')
        assert [entry['branch'] for entry in tracked if entry['worktree_id'] is not None] == ['locked'], tracked
        self.git('worktree', 'unlock', str(locked))
        self.call('worktree-remove-unlocked', 'worktree', 'remove', 'locked')
        assert not locked.exists()
        # A person who confirms at the terminal discards the changes and the unmerged commits.
        doomed = Path(self.call('worktree-create-confirmed', 'worktree', 'create', 'confirmed', '--json')['path'])
        (doomed / 'file.txt').write_text('discarded\n')
        self.git('commit', '-qam', 'Unmerged and discarded', cwd=doomed)
        (doomed / 'file.txt').write_text('uncommitted\n')
        self.answer('worktree-remove-confirmed', b'y\nyes', 'worktree', 'remove', 'confirmed', '--force', '--delete-branch', '--json')
        assert not doomed.exists() and not self.git('branch', '--list', 'confirmed').strip()
        self.call('worktree-list-untracked', 'worktree', 'list', '--json')
        self.call('worktree-list-untracked-text', 'worktree', 'list')
        self.call('worktree-adopt-diff', 'worktree', 'diff', 'manual')
        self.call('worktree-remove-adopted', 'worktree', 'remove', 'manual', '--json')
        self.call('workspace-worktree-alias', 'workspace', 'create', '--worktree', 'alias', '--name', 'Alias', '--json')
        self.call('worktree-remove-alias', 'worktree', 'remove', 'alias')
        self.call('worktree-missing', 'worktree', 'diff', 'missing', status=2)
        self.call('worktree-open-missing', 'worktree', 'open', 'missing', status=2)
        self.call('worktree-remove-missing', 'worktree', 'remove', 'missing', status=2)
        self.exercise_worktree_options(wid)
        (self.repo / '.telar').mkdir()
        (self.repo / '.telar/setup.json').write_text('{"version":1,"argv":["/bin/sh","-c","printf setup-output; touch setup-ready"]}')
        self.git('add', '.telar/setup.json')
        self.git('commit', '-qm', 'Setup fixture')
        self.call('worktree-setup-no-flag', 'worktree', 'create', 'setup-gated', '--json', status=1)
        assert (self.root / 'repo-worktrees/setup-gated').is_dir()
        assert not (self.root / 'repo-worktrees/setup-gated/setup-ready').exists()
        self.call('worktree-remove-setup-gated', 'worktree', 'remove', 'setup-gated')
        ready = self.call('worktree-setup-authorized', 'worktree', 'create', 'setup-yes', '--setup', '--json')
        assert Path(ready['path'], 'setup-ready').exists()
        Path(ready['path'], 'setup-ready').unlink()
        self.call('worktree-remove-setup-yes', 'worktree', 'remove', 'setup-yes')
        for index, recipe in enumerate([
                '{}', '{"version":2,"argv":["/usr/bin/true"]}',
                '{"version":true,"argv":["/usr/bin/true"]}',
                '{"version":1.5,"argv":["/usr/bin/true"]}',
                '{"version":256,"argv":["/usr/bin/true"]}',
                '{"version":1,"argv":[]}', '{"version":1,"argv":[1]}',
                '{"version":1,"argv":["/usr/bin/true"],"extra":true}',
                '{"version":1,"version":1,"argv":["/usr/bin/true"]}', '{not json',
                '{"version":"0x1","argv":["/usr/bin/true"]}']):
            (self.repo / '.telar/setup.json').write_text(recipe)
            self.git('add', '.telar/setup.json')
            self.git('commit', '-qm', f'Invalid setup {index}')
            branch = f'setup-bad-{index}'
            self.call('worktree-invalid-setup-' + str(index), 'worktree', 'create', branch, '--setup', '--json', status=1)
            self.call('worktree-remove-invalid-setup-' + str(index), 'worktree', 'remove', branch)
        for index, recipe in enumerate([
                '{"version":"1","argv":["/usr/bin/true"]}',
                '{"version":1.0,"argv":["/usr/bin/true"]}',
                '{"\\u0076ersion":1,"argv":["/usr/bin/true"]}']):
            (self.repo / '.telar/setup.json').write_text(recipe)
            self.git('add', '.telar/setup.json')
            self.git('commit', '-qm', f'Numeric setup {index}')
            branch = f'setup-valid-{index}'
            ready = self.call('worktree-numeric-setup-' + str(index), 'worktree', 'create', branch, '--setup', '--json')
            assert ready['environment'] == 'ready'
            self.call('worktree-remove-numeric-setup-' + str(index), 'worktree', 'remove', branch)
        (self.repo / '.telar/setup.json').unlink()
        (self.repo / '.telar/setup.json').symlink_to('recipe.json')
        (self.repo / '.telar/recipe.json').write_text('{"version":1,"argv":["/usr/bin/true"]}')
        self.git('add', '.telar')
        self.git('commit', '-qm', 'Symlink setup fixture')
        self.call('worktree-symlink-setup', 'worktree', 'create', 'setup-link', '--setup', '--json', status=1)
        self.call('worktree-remove-symlink-setup', 'worktree', 'remove', 'setup-link')
        self.git('rm', '.telar/setup.json')
        self.git('rm', '.telar/recipe.json')
        self.git('commit', '-qm', 'Remove setup fixture')
        linked = self.root / 'repo-link'
        linked.symlink_to(self.repo, target_is_directory=True)
        canonical = self.call('workspace-create-symlink', 'workspace', 'create', '--directory', str(linked), '--name', 'Linked', '--json')
        assert canonical['directory'] == str(self.repo)
        self.call('workspace-close-symlink', 'tab', 'close', str(canonical['tab_id']), '--workspace', str(canonical['workspace_id']), '--json')
        assert self.call('tab-close-last', 'tab', 'close', tid, '--workspace', wid, '--json')['workspace_closed'] is True
        self.call('workspace-list-after-close', 'workspace', 'list', '--json')
        self.call('worktree-resolve-explicit-closed', 'worktree', 'resolve', '--repository', 'example.invalid/team/repo', '--workspace', str(self.repo), '--json')
        self.call('worktree-resolve-history', 'worktree', 'resolve', '--repository', 'example.invalid/team/repo', '--json')
        self.exercise_opened_source()
        if self.gui:
            created = self.call('gui-fixture-workspace', 'workspace', 'create', '--directory', str(self.repo), '--json')
            self.call('gui-fixture-worktree', 'worktree', 'create', 'gui-task', '--title', 'GUI task', '--json')
            self.exercise_gui(str(created['workspace_id']), str(created['tab_id']))
        return self.results

    def listed(self, name, *words):
        return {entry['branch']: entry for entry in self.call(name, 'worktree', 'list', *words, '--json') if entry['worktree_id'] is not None}

    def exercise_worktree_options(self, wid):
        # The first pane runs the command after `--`, not the login shell.
        command = self.call('workspace-create-command', 'workspace', 'create', '--directory', str(self.repo), '--name', 'Command', '--json',
                            '--', '/bin/sh', '-c', 'echo marker-$((6*7)); exec sleep 60')
        deadline = time.monotonic() + 10
        while 'marker-42' not in invoke(self.binary, ['pane', 'read', str(command['pane_id'])], self.env, self.repo, self.socket)['stdout']:
            assert time.monotonic() < deadline, 'the command after -- did not run in the first pane'
            time.sleep(.05)
        self.call('workspace-close-command', 'tab', 'close', str(command['tab_id']), '--workspace', str(command['workspace_id']), '--json')

        # --from starts the branch at another base and --directory puts the checkout elsewhere.
        tree = self.git('rev-parse', 'HEAD^{tree}').decode().strip()
        dev = self.git('commit-tree', tree, '-p', 'HEAD', '-m', 'Dev base').decode().strip()
        self.git('update-ref', 'refs/heads/dev', dev)
        elsewhere = self.root / 'elsewhere' / 'from-dev'
        created = self.call('worktree-create-from', 'worktree', 'create', 'from-dev', '--from', 'dev', '--directory', str(elsewhere), '--json')
        assert created['path'] == str(elsewhere) and created['base'] == 'dev', created
        assert self.git('rev-parse', 'HEAD', cwd=elsewhere).decode().strip() == dev

        # The brief keeps the prompt's text: no control byte, at most 512 bytes, no split character.
        prompt = 'do\x01 it ' + 'x' * 505 + 'é' * 800
        self.call('worktree-create-brief', 'worktree', 'create', 'briefed', '--title', 'Briefed', '--dispatched-from', 'laptop', '--json',
                  '--', '/bin/echo', prompt)
        tracked = self.listed('worktree-list-brief')
        brief = tracked['briefed']['brief']
        assert brief and len(brief.encode()) <= 512 and prompt.replace('\x01', '').startswith(brief), brief
        assert tracked['briefed']['dispatched_from'] == 'laptop', tracked['briefed']

        # After a commit on the worktree, a commit on the base and an uncommitted edit, the diff
        # shows the branch's work since the merge base, and --uncommitted only the edit.
        diffed = Path(self.call('worktree-create-diffed', 'worktree', 'create', 'diffed', '--json')['path'])
        (diffed / 'committed.txt').write_text('branch work\n')
        self.git('add', 'committed.txt', cwd=diffed)
        self.git('commit', '-qm', 'Branch work', cwd=diffed)
        (diffed / 'file.txt').write_text('base\nuncommitted\n')
        (self.repo / 'main-only.txt').write_text('main work\n')
        self.git('add', 'main-only.txt')
        self.git('commit', '-qm', 'Main work')
        work = self.call('worktree-diff-work', 'worktree', 'diff', 'diffed')
        assert 'committed.txt' in work and 'main-only.txt' not in work, work
        uncommitted = self.call('worktree-diff-uncommitted', 'worktree', 'diff', 'diffed', '--uncommitted')
        assert '+uncommitted' in uncommitted and 'committed.txt' not in uncommitted, uncommitted
        stat = self.call('worktree-diff-stat-work', 'worktree', 'diff', 'diffed', '--stat')
        assert 'committed.txt |' in stat and '+++' not in stat, stat
        self.git('checkout', '--', 'file.txt', cwd=diffed)

        # In an agent's pane, TELAR_WORKSPACE_ID names the repository, whatever the directory.
        other = self.root / 'other'
        other.mkdir()
        self.git('init', '-q', '-b', 'main', cwd=other)
        self.git('commit', '-q', '--allow-empty', '-m', 'Other', cwd=other)
        current = invoke(self.binary, ['worktree', 'create', 'current-ws', '--json'], dict(self.env, TELAR_WORKSPACE_ID=wid), other, self.socket)
        assert current['status'] == 0, current
        assert Path(json.loads(current['stdout'])['path']).parent == self.root / 'repo-worktrees', current

        # --workspace keeps only the worktrees of that repository, by id or directory.
        opened = self.call('workspace-create-other', 'workspace', 'create', '--directory', str(other), '--json')
        made = invoke(self.binary, ['worktree', 'create', 'other-task', '--json'], self.env, other, self.socket)
        assert made['status'] == 0, made
        for name, words in (('worktree-list-source-id', ('--workspace', wid)), ('worktree-list-source-path', ('--workspace', str(self.repo)))):
            assert 'other-task' not in self.listed(name, *words) and 'briefed' in self.listed(name, *words)
        assert set(self.listed('worktree-list-other-id', '--workspace', str(opened['workspace_id']))) == {'other-task'}
        self.call('worktree-list-unknown-source', 'worktree', 'list', '--workspace', str(self.root / 'nowhere'), '--json', status=2)

        for branch in ('from-dev', 'briefed', 'diffed', 'current-ws'):
            self.call('worktree-remove-option-' + branch, 'worktree', 'remove', branch, '--json')
        assert invoke(self.binary, ['worktree', 'remove', 'other-task'], self.env, other, self.socket)['status'] == 0
        self.call('workspace-close-other', 'tab', 'close', str(opened['tab_id']), '--workspace', str(opened['workspace_id']), '--json')

    def exercise_opened_source(self):
        # With no workspace on the repository, `worktree create` opens one on its root.
        assert not [entry for entry in self.call('workspace-list-before-source', 'workspace', 'list', '--json') if entry['path'] == str(self.repo)]
        self.call('worktree-create-opens-source', 'worktree', 'create', 'sourced', '--json')
        source = self.listed('worktree-list-sourced')['sourced']['source_workspace_id']
        workspaces = {entry['workspace_id']: entry['path'] for entry in self.call('workspace-list-sourced', 'workspace', 'list', '--json')}
        assert workspaces.get(source) == str(self.repo), (source, workspaces)
        self.call('worktree-remove-sourced', 'worktree', 'remove', 'sourced')

    def exercise_gui(self, wid, tid):
        env = dict(self.env, TELAR_SOCKET=str(self.socket), TELAR_SOCKET_PATH=str(self.socket))
        log = (self.root / 'gui.log').open('wb')
        args = [str(self.gui), '--socket', str(self.socket), '--no-config', '--smoke-ms', '180000']
        self.window = subprocess.Popen(args, env=env, cwd=self.repo, stdout=log, stderr=log, start_new_session=True)
        log.close()
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if self.window.poll() is not None:
                raise RuntimeError((self.root / 'gui.log').read_text())
            clients = invoke(self.binary, ['client', 'list', '--json'], self.env, self.repo, self.socket)
            # C++ client list is in the window package; use the read-only probe
            # below when the independently ported CLI does not have it yet.
            if clients['status'] == 0:
                rows = json.loads(clients['stdout'])
            else:
                rows = probe_clients(self.socket)
            if rows:
                client = str(rows[0].get('client_id', rows[0].get('id')))
                break
            time.sleep(.05)
        else:
            raise RuntimeError('GUI did not register a client')
        time.sleep(.5)
        self.results['gui-worktree-open'] = invoke(self.binary, ['worktree', 'open', 'GUI task', '--client', client, '--json'], self.env, self.repo, self.socket)
        time.sleep(.2)
        self.results['gui-worktree-open-default'] = invoke(self.binary, ['worktree', 'open', 'GUI task', '--json'], self.env, self.repo, self.socket)
        time.sleep(.2)
        # Preserve refusals as evidence too; GUI differences are reported per case.
        for name, words in [
            ('gui-workspace-select', ['workspace', 'select', wid]),
            ('gui-workspace-select-again', ['workspace', 'select', wid]),
            ('gui-tab-select', ['tab', 'select', tid]),
            ('gui-tab-create', ['tab', 'create', '--label', 'Window tab']),
            ('gui-tab-next', ['tab', 'next']), ('gui-tab-previous', ['tab', 'previous'])]:
            self.results[name] = invoke(self.binary, [*words, '--client', client, '--json'], self.env, self.repo, self.socket)
            time.sleep(.2)
            if name == 'gui-tab-create' and self.results[name]['status'] == 0:
                deadline = time.monotonic() + 5
                while True:
                    result = invoke(self.binary, ['tab', 'list', '--workspace', wid, '--json'], self.env, self.repo, self.socket)
                    rows = json.loads(result['stdout'])
                    new_tab = next((row['tab_id'] for row in rows if row['label'] == 'Window tab'), None)
                    if new_tab is not None:
                        break
                    assert time.monotonic() < deadline, result
                    time.sleep(.05)
                self.results['gui-tab-list-after-create'] = result
                for target, suffix in [(tid, 'original'), (str(new_tab), 'created')]:
                    self.results['gui-tab-select-change-' + suffix] = invoke(self.binary, ['tab', 'select', target, '--client', client, '--json'], self.env, self.repo, self.socket)
                    time.sleep(.2)


def probe_clients(path):
    import socket
    import struct
    def exact(connection, size):
        result = b''
        while len(result) < size:
            part = connection.recv(size - len(result))
            if not part:
                raise RuntimeError('EOF reading clients')
            result += part
        return result
    def frame(connection):
        return exact(connection, struct.unpack('<I', exact(connection, 4))[0])
    def send(connection, payload):
        connection.sendall(struct.pack('<I', len(payload)) + payload)
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        send(connection, b'TELARIPC\x01cqp00006')
        assert frame(connection) == b'TELARIPC\x02cqp00006'
        send(connection, b'\x33' + struct.pack('<Q', 1))
        payload = frame(connection)
        assert payload[0] == 0xad
        header_bytes = 1 + struct.calcsize('<Q')
        count = payload[header_bytes]
        entries_offset = header_bytes + struct.calcsize('<B')
        descriptor_bytes = struct.calcsize('<QQQHQQ')
        return [{'client_id': struct.unpack_from('<Q', payload, entries_offset + index * descriptor_bytes)[0]} for index in range(count)]


def normalized(results):
    ids = {}
    def identity(kind, value):
        if value is None or value == 0 or value == 999999:
            return value
        kind = 'workspace_id' if kind == 'source_workspace_id' else kind
        mapping = ids.setdefault(kind, {})
        return mapping.setdefault(value, len(mapping) + 1)
    converted = {}
    for name, result in results.items():
        result = dict(result)
        try:
            json.loads(result['stdout'])
            def replace_field(match):
                key, number = match.group(2), int(match.group(3))
                if key in ('pane_generation', 'client_generation'):
                    number = 1
                elif key == 'status_age_s':
                    number = 0
                else:
                    number = identity(key, number)
                return match.group(1) + str(number)
            result['stdout'] = re.sub(r'((?<!\\)"([a-z_]+(?:_id|_generation)|status_age_s)":)([0-9]+)', replace_field, result['stdout'])
        except (ValueError, TypeError):
            # Text rows and diagnostics have runtime-generated numeric identities.
            # Keep column positions and user data untouched.
            text = result['stdout']
            text = re.sub(r'(?<=workspace )\d+|(?<=tab )\d+|(?<=pane )\d+|(?<=client )\d+', '<id>', text)
            if name.startswith('tab-get'):
                text = re.sub(r'^\d+\t\d+\t', '<pane>\t<gen>\t', text, flags=re.M)
            if name.startswith('workspace-get'):
                text = re.sub(r'^\d+\t', '<workspace>\t', text, flags=re.M)
            if name == 'tab-list-text':
                text = re.sub(r'^\d+\t', '<tab>\t', text, flags=re.M)
            result['stdout'] = text
        result['stderr'] = re.sub(r'(?<=setup execution )\d+|(?<=; pane )\d+', '<id>', result['stderr'])
        converted[name] = result
    return converted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cpp', type=Path, required=True)
    parser.add_argument('--gui', type=Path)
    parser.add_argument('--scratch', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--validation-only', action='store_true')
    args = parser.parse_args()
    binary = args.cpp.resolve()
    with tempfile.TemporaryDirectory(prefix='ses-', dir=args.scratch) as temporary:
        fixture = Path(temporary).resolve() / 'f'
        fixture.mkdir()
        records = validation(binary, fixture)
        if not args.validation_only:
            stack = Stack(binary, fixture, args.gui)
            try:
                records.update(stack.exercise())
            finally:
                stack.stop()
        report = {'binary': {'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'path': str(binary)}, 'results': normalized(records)}
        if args.output:
            args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
        print(f"{len(report['results'])} cases")
        return 0


if __name__ == '__main__':
    raise SystemExit(main())
