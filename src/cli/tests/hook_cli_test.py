#!/usr/bin/env python3
"""`telar hook`: what reaches the runtime, what Claude reads back, and that the agent never sees a failure."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from check_hook_cli import run_case

VERIFY_PANE_DESCENT = 0x42
REPORTS = {0x20, 0x2a, 0x2b, 0x40}
REPORT_AGENT_COMMAND = 0x2a
REGISTER_WORKTREE = 0x3c
CLAUDE = 1


def frames(result):
    return [bytes.fromhex(frame) for frame in result['frames']]


def reports_own_pane(binary, root):
    """Every report names the pane the hook runs in, after the runtime verified the hook descends from it."""
    event = {'hook_event_name': 'SessionStart', 'cwd': str(root), 'session_title': 'Fixture', 'session_id': 'fixture',
             'pane_id': 99, 'pane_generation': 7, 'TELAR_PANE_ID': '99'}
    result, _ = run_case(binary, root, {'provider': 'claude', 'input': event})
    sent = frames(result)
    assert result['status'] == 0, result
    assert sent and sent[0][0] == VERIFY_PANE_DESCENT, result
    assert struct.unpack('<QQ', sent[0][9:25]) == (17, 29), sent[0].hex()

    reports = [frame for frame in sent if frame[0] in REPORTS]
    assert reports, result
    for frame in reports:
        assert struct.unpack('<QQ', frame[9:25]) == (17, 29), frame.hex()
        if frame[0] == REPORT_AGENT_COMMAND:
            assert frame[28:28 + struct.unpack('<H', frame[26:28])[0]] == b'claude', frame.hex()
        else:
            assert frame[25] == CLAUDE, frame.hex()


def never_fails_the_agent(binary, root):
    """No input, runtime or socket makes the hook fail: Claude Code blocks the agent on a hook's exit 2."""
    def claude(text):
        return {'provider': 'claude', 'input': text.encode()}

    malformed = [
        claude('not json'),
        {'provider': 'claude', 'input': b'{"hook_event_name":"SessionStart","session_title":"\xff\xfe"}'},
        claude('{"hook_event_name":"SessionStart","hook_event_name":"Stop","session_title":"Duplicate"}'),
        claude('{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"t","tool_input":{"command":"a","command":"b"}}'),
        claude('{"hook_event_name":"PostToolUse","tool_name":"TodoWrite","tool_input":{"todos":[{"content":"a","content":"b","status":"pending"}]}}'),
        claude('{"hook_event_name":"SessionStart","session_title":"\\ud800"}'),
        {'provider': 'pi', 'input': {'event': 'tool_execution_end', 'tool_name': 'bash', 'tool_call_id': 't', 'tool_input': {'command': 'true'}, 'exit_code': 'abc'}},
    ]
    for case in malformed:
        result, _ = run_case(binary, root, case)
        assert result['status'] == 0 and result['stdout'] == '', (case, result)
        assert not [frame for frame in frames(result) if frame[0] in REPORTS], (case, result)

    start = {'hook_event_name': 'SessionStart', 'cwd': str(root), 'session_title': 'Fixture'}
    refused, _ = run_case(binary, root, {'provider': 'claude', 'input': start, 'refusal': VERIFY_PANE_DESCENT})
    assert refused['status'] == 0 and refused['stdout'] == '', refused
    assert [frame[0] for frame in frames(refused)] == [VERIFY_PANE_DESCENT], refused

    environment = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    missing = subprocess.run([str(binary), 'hook', 'claude', '--socket', str(root / 'absent.sock')], input=json.dumps(start).encode(),
                             env=environment | {'HOME': str(root), 'TELAR_PANE_ID': '17', 'TELAR_PANE_GENERATION': '29'}, capture_output=True, timeout=15)
    assert missing.returncode == 0 and missing.stdout == b'', missing


def git(*args, cwd, env):
    return subprocess.run(['git', *args], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


def git_environment(root):
    env = {key: value for key, value in os.environ.items() if not key.startswith(('TELAR_', 'GIT_'))}
    env.update({'HOME': str(root), 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CEILING_DIRECTORIES': str(root),
                'GIT_AUTHOR_NAME': 'fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
                'GIT_COMMITTER_NAME': 'fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid'})
    return env


def fixture_repository(root, env):
    repository = root / 'repository'
    repository.mkdir()
    git('init', '-q', '-b', 'main', cwd=repository, env=env)
    (repository / 'tracked.txt').write_text('base\n')
    git('add', 'tracked.txt', cwd=repository, env=env)
    git('-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'base', cwd=repository, env=env)
    return repository


def worktree_create_prints_path(binary, root):
    """Claude opens the path the WorktreeCreate hook prints: stdout is that path and nothing else."""
    env = git_environment(root)
    repository = fixture_repository(root, env)
    head = git('rev-parse', 'HEAD', cwd=repository, env=env)

    def create():
        event = {'session_id': 'fixture', 'hook_event_name': 'WorktreeCreate', 'cwd': str(repository), 'name': 'feat/x'}
        result = subprocess.run([str(binary), 'hook', 'claude', '--socket', str(root / 'absent.sock')], input=json.dumps(event).encode(),
                                env=env, capture_output=True, timeout=30)
        assert result.returncode == 0, result
        lines = result.stdout.decode().splitlines()
        assert len(lines) == 1 and result.stdout.endswith(b'\n'), result
        path = Path(lines[0])
        assert path.is_absolute() and path.is_dir(), result
        return path

    created = create()
    assert git('rev-parse', 'feat/x', cwd=repository, env=env) == head
    assert git('rev-parse', '--abbrev-ref', 'HEAD', cwd=created, env=env) == 'feat/x'

    # The branch outlives its checkout: a second create checks out its tip, not HEAD.
    (created / 'tracked.txt').write_text('on the branch\n')
    git('-c', 'commit.gpgsign=false', 'commit', '-qam', 'branch work', cwd=created, env=env)
    tip = git('rev-parse', 'HEAD', cwd=created, env=env)
    git('worktree', 'remove', str(created), cwd=repository, env=env)

    reused = create()
    assert git('rev-parse', 'HEAD', cwd=reused, env=env) == tip != head
    assert git('rev-parse', '--abbrev-ref', 'HEAD', cwd=reused, env=env) == 'feat/x'


def create_worktree(binary, root, env, cwd, name):
    event = {'session_id': 'fixture', 'hook_event_name': 'WorktreeCreate', 'cwd': str(cwd), 'name': name}
    return subprocess.run([str(binary), 'hook', 'claude', '--socket', str(root / 'absent.sock')], input=json.dumps(event).encode(),
                          env=env, capture_output=True, timeout=30)


def worktree_branch_name_sanitized(binary, root):
    """A name the agent chose becomes a branch Git accepts and that no Git command reads as an option."""
    env = git_environment(root)
    repository = fixture_repository(root, env)
    result = create_worktree(binary, root, env, repository, '-rf ../x y~z')
    assert result.returncode == 0, result
    path = Path(result.stdout.decode().strip())
    branch = git('rev-parse', '--abbrev-ref', 'HEAD', cwd=path, env=env)
    assert branch and not branch.startswith(('-', '.')) and '..' not in branch and not {' ', '~'} & set(branch), branch
    assert path.parent == repository.parent / 'repository-worktrees', path

    # A name with nothing usable creates no worktree and no output for Claude to open.
    refused = create_worktree(binary, root, env, repository, '...')
    assert refused.returncode == 1 and refused.stdout == b'', refused
    listed = git('worktree', 'list', '--porcelain', cwd=repository, env=env)
    assert listed.count('worktree ') == 2, listed


def worktree_create_outside_repo_fails(binary, root):
    """Outside a repository the hook fails without a path, so Claude does not carry on without a worktree."""
    env = git_environment(root)
    plain = root / 'plain'
    plain.mkdir()
    result = create_worktree(binary, root, env, plain, 'feature')
    assert result.returncode != 0 and result.stdout == b'', result


def worktree_registered_with_runtime(binary, root):
    """The runtime tracks a worktree the hook creates; a failed registration still leaves Claude its worktree."""
    env = git_environment(root)
    repository = fixture_repository(root, env)

    def create(name, workspace, refusal=None):
        event = {'session_id': 'fixture', 'hook_event_name': 'WorktreeCreate', 'cwd': str(repository), 'name': name}
        environment = {key: value for key, value in env.items() if key.startswith('GIT_')} | {'TELAR_WORKSPACE_ID': workspace}
        result, _ = run_case(binary, root, {'provider': 'claude', 'input': event, 'environment': environment, 'refusal': refusal})
        assert result['status'] == 0, result
        path = bytes.fromhex(result['stdout']).decode().strip()
        assert Path(path).is_dir(), result
        return path, [frame for frame in frames(result) if frame[0] == REGISTER_WORKTREE]

    path, registered = create('feat/y', '3')
    assert len(registered) == 1, registered
    frame = registered[0]
    assert struct.unpack('<Q', frame[9:17])[0] == 3 and frame[17] == 1 and struct.unpack('<Q', frame[18:26])[0] == 17, frame.hex()
    fields, offset = [], 27
    for _ in range(3):
        length = struct.unpack('<H', frame[offset:offset + 2])[0]
        fields.append(frame[offset + 2:offset + 2 + length].decode())
        offset += 2 + length
    assert fields == [path, 'feat/y', 'main'], fields

    _, refused = create('feat/z', '3', refusal=REGISTER_WORKTREE)
    assert len(refused) == 1, refused
    _, untracked = create('feat/w', '0')
    assert not untracked, untracked


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--telar', type=Path, required=True)
    args = parser.parse_args()
    binary = args.telar.resolve()
    for check in (reports_own_pane, never_fails_the_agent, worktree_create_prints_path, worktree_branch_name_sanitized,
                  worktree_create_outside_repo_fails, worktree_registered_with_runtime):
        with tempfile.TemporaryDirectory(prefix='hook-cli-', dir=os.environ.get('TMPDIR')) as directory:
            check(binary, Path(directory).resolve())
    print('hook cli cases passed')


if __name__ == '__main__':
    main()
