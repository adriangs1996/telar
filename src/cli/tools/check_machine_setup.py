#!/usr/bin/env python3
"""Check setup's file sync through a substituted gateway program and real receivers."""
import contextlib
import json
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import tempfile
import types
from check_machines_launch import GATEWAY_ARGV, NOT_PAIRED, VERSION, address, environment, install_gateway, normalize, snapshot

# The machine every setup here reaches, and the address `telar server pair` would print for it.
FIXTURE = address('fixture')
PAIRING = FIXTURE + '.' + '0123456789abcdef' * 2

SHIM = GATEWAY_ARGV + r'''import os,subprocess,json,shlex,base64
from pathlib import Path
home=os.environ['FIXTURE_REMOTE_HOME']
schema=os.environ['FIXTURE_SCHEMA']
mode=os.environ.get('FIXTURE_LOGIN','')
state=Path(home)/'fixture-pane.json'
def person(words):
 # The person's own workspace 11, whose ids a stale login record still names; setup's login
 # pane is workspace 21.
 if words[:2]==['workspace','create']:
  state.write_text(json.dumps({'title':words[words.index('--name')+1]}))
  print(json.dumps({'workspace_id':21,'tab_id':22,'pane_id':23}))
 elif words[:2]==['workspace','list']:
  print(json.dumps([{'workspace_id':11,'name':'My work'}]+([{'workspace_id':21,'name':json.loads(state.read_text())['title']}] if state.exists() else [])))
 elif words[:2] in (['tab','get'],['tab','close']):
  workspace,tab=int(words[words.index('--workspace')+1]),int(words[2])
  print(json.dumps({'workspace_id':workspace,'tab_id':tab,'panes':[{'pane_id':tab+1}],'closed':True}))
 elif words[:2]==['pane','read']:
  print(json.dumps({'pane_id':int(words[2]),'truncated':False,'exit_code':0,'text':''}))
 else:raise RuntimeError(words)
def respond(words):
 if os.environ.get('FIXTURE_ARGV'):
  with open(os.environ['FIXTURE_ARGV'],'a') as log:log.write(json.dumps(words)+'\n')
 if os.environ.get('FIXTURE_PERSON'):
  return person(words)
 if words[:2]==['workspace','create']:
  state.write_text(json.dumps({'title':words[words.index('--name')+1]}))
  print(json.dumps({'workspace_id':11,'tab_id':12,'pane_id':13}))
 elif words[:2]==['workspace','list']:
  print(json.dumps([{'workspace_id':11,'name':json.loads(state.read_text())['title']}] if state.exists() else []))
 elif words[:2]==['tab','get']:
  print(json.dumps({'workspace_id':11,'tab_id':12,'panes':[{'pane_id':13}]}))
 elif words[:2]==['tab','close']:
  state.unlink(missing_ok=True)
  print(json.dumps({'workspace_id':11,'tab_id':12,'closed':True}))
 elif words[:2]==['pane','read']:
  if mode=='lost':
   print('telar pane: pane not found or its generation is stale',file=sys.stderr);sys.exit(2)
  text=os.environ.get('FIXTURE_PANE_TEXT','https://evil.invalid/ignore https://claude.com/oauth/authorize?fixture=safe')
  print(json.dumps({'pane_id':13,'truncated':False,'exit_code':7 if mode=='failed' else 0 if mode=='ended' else None,'text':text}))
 elif words[:2]==['pane','send-keys']:
  sent=sys.stdin.buffer.read()
  if os.environ.get('FIXTURE_SENT'):
   with open(os.environ['FIXTURE_SENT'],'ab') as log:log.write(json.dumps({'words':words,'text':sent.decode()}).encode()+b'\n')
 else:raise RuntimeError(words)

if os.environ.get('FIXTURE_CALLS'):
 with open(os.environ['FIXTURE_CALLS'],'a') as log:log.write(json.dumps({'argv':sys.argv[1:],'terminal':os.isatty(0)})+'\n')
remote_env=dict(os.environ,HOME=home,PATH=home+'/.local/bin:/usr/bin:/bin')
# A pairing address enrolls this machine by its name and leaves the address to save; with
# FIXTURE_AUTH=once the gateway admits no machine before that.
paired=Path(home)/'fixture-paired'
if request['verb']=='enroll':
 paired.write_text(request['name']+'\n');print(request['destination'].rpartition('.')[0]);sys.exit(0)
if os.environ.get('FIXTURE_AUTH')=='once' and not paired.exists():
 print('@NOT_PAIRED@',file=sys.stderr);sys.exit(255)
if ' dispatch-argv ' in command:
 words=[base64.urlsafe_b64decode(word[1:]+'='*((-len(word[1:]))%4)).decode() for word in command.split(' dispatch-argv ',1)[1].split()]
 respond(words)
elif command.endswith("server endpoint'") and os.environ.get('FIXTURE_ENDPOINT')=='mismatch' and not (Path(home)/'stopped').exists():
 print('telar protocol mismatch',file=sys.stderr);sys.exit(1)
elif command.endswith("server endpoint'"):
 print(home);print('/bin/sh');print(home+'/runtime.sock');print(schema)
elif command.endswith(' machine receive-config') and os.environ.get('FIXTURE_RECEIVE')=='fail':
 sys.stdin.buffer.read();print('cannot write there',file=sys.stderr);sys.exit(1)
elif command.startswith('exec /bin/sh -c ') and '/telar/nvim;' in command:
 # The package's own Neovim, sent over standard input: unpacked in the remote home for real,
 # which has none of this side's XDG directories.
 sys.exit(subprocess.run(['/bin/sh','-c',command],env={key:value for key,value in remote_env.items() if not key.startswith('XDG_')}).returncode)
elif os.environ.get('FIXTURE_REAL') and command.startswith('exec /bin/sh -c '):
 sys.exit(subprocess.run(['/bin/sh','-c',command],env=remote_env).returncode)
elif command.endswith(' machine receive-config'):
 env=dict(os.environ,HOME=home)
 result=subprocess.run([os.environ['FIXTURE_TELAR'],'machine','receive-config'],input=sys.stdin.buffer.read(),env=env)
 sys.exit(result.returncode)
else:
 script=sys.stdin.read()
 probe=os.environ.get('FIXTURE_PROBE','')
 if script.startswith('dir=') and probe=='banner':print('Welcome to the fixture host')
 elif script.startswith('dir=') and probe=='exit3':print('the probe broke there',file=sys.stderr);sys.exit(3)
 elif os.environ.get('FIXTURE_REAL') or (os.environ.get('FIXTURE_SCRIPTS')=='real' and not script.startswith('dir=')):
  sys.exit(subprocess.run(['/bin/sh','-s'],input=script,text=True,env=remote_env).returncode)
 elif script.startswith('dir='):
  print('os=Darwin\narch=arm64\nlibc=gnu\nhome='+home)
  print('target='+home+'/.local/share/telar/versions/0.0.0/telar')
  print('installed=telar 0.0.0')
  if os.environ.get('FIXTURE_PROBE_EXTRA'):print(os.environ['FIXTURE_PROBE_EXTRA'])
  if os.environ.get('FIXTURE_LOGIN'):
   for agent in os.environ.get('FIXTURE_THERE','claude').split(','):print('agent='+agent+':'+home+'/'+agent)
 elif mode and script.startswith('agent='):
  count=Path(home)/'fixture-auth-count'
  before=int(count.read_text()) if count.exists() else 0
  count.write_text(str(before+1))
  if mode=='unreachable':sys.exit(255)
  # 'paste' logs in once the person has answered, its pane still open.
  sys.exit(0 if mode=='done' or mode in ('ended','paste') and before>0 else 1)
 elif mode and script.startswith(('cat "','rm -f "','umask 077 && mkdir')):
  sys.exit(subprocess.run(['/bin/sh','-s'],input=script,text=True,env=dict(os.environ,HOME=home)).returncode)
 elif mode and script.startswith('exec '):
  respond(shlex.split(script)[1:][1:])
 elif script.startswith('while IFS= read -r path;'):
  for path in script.split("TELAR_PATHS'\n",1)[-1].splitlines():
   if os.path.exists(path):print(path)
'''.replace('0.0.0', VERSION).replace('@NOT_PAIRED@', NOT_PAIRED)


# A login shell that answers nothing: setup asks one for the PATH it sets, and a real one reads
# the system's profile, which names the agents of whoever runs these checks. Outside the
# directories a check records.
QUIET_LOGIN_SHELL = shutil.which('false')


def run(binary, provider, seed, login=False, prepare=None):
    """Runs setup twice; `prepare(root, env)`, when given, changes either side before."""
    with tempfile.TemporaryDirectory(prefix='telar-sync-',dir='/tmp') as temporary:
        root=Path(temporary).resolve();env=environment(root)
        home=Path(env['HOME']);remote=root/'remote';remote.mkdir(mode=0o700)
        bindir=root/'bin';bindir.mkdir();install_gateway(bindir,env,SHIM)
        env['SHELL']=QUIET_LOGIN_SHELL
        command='cursor-agent' if provider=='cursor' else provider
        (bindir/command).write_text('#!/bin/sh\nexit 0\n');(bindir/command).chmod(0o700)
        env['PATH']=str(bindir)+':/usr/bin:/bin'
        if login:env['FIXTURE_LOGIN']=login
        env.update(FIXTURE_REMOTE_HOME=str(remote),FIXTURE_TELAR=str(binary),FIXTURE_SCHEMA='cqp00009' if b'cqp00009' in binary.read_bytes() else '886b480d')
        roots={'claude':home/'.claude','codex':home/'.codex','pi':home/'.pi/agent','opencode':Path(env['XDG_CONFIG_HOME'])/'opencode','cursor':home/'.cursor'}
        local=roots[provider];local.mkdir(parents=True,mode=0o700)
        filename={'claude':'settings.json','codex':'config.toml','pi':'settings.json','opencode':'opencode.jsonc','cursor':'hooks.json'}[provider]
        (local/filename).write_text(seed.replace('@HOME@',str(home)).replace('@ROOT@',str(root)))
        skills=local/'skills/custom';skills.mkdir(parents=True)
        (skills/'SKILL.md').write_text('A private-home path: '+str(home)+'/project\n')
        (skills/'secret.txt').write_text('API_KEY=literal-secret-value\n')
        (local/'auth.json').write_text('never transfer me')
        (local/'projects').mkdir();(local/'projects/session.txt').write_text('never transfer sessions')
        (local/'tool.sh').write_text('#!/bin/sh\necho safe\n');(local/'tool.sh').chmod(0o755)
        (skills/'outside').symlink_to(root/'outside');(root/'outside').write_text('outside root')
        profiles=Path(env['XDG_CONFIG_HOME'])/'telar/machines.json';profiles.parent.mkdir(exist_ok=True,mode=0o700)
        if prepare:prepare(root,env)
        result=[]
        for repetition in range(2):
            child=subprocess.run([str(binary),'machine','setup',FIXTURE,'--skip','agents,config,editor' if login else 'agents,login,editor','--json'],env=env,cwd=root,capture_output=True,text=True,timeout=90)
            files=snapshot(root,binary)
            # Fixture files contain implementation paths and schema by design.
            result.append({'status':child.returncode,'stdout':normalize(child.stdout,root,binary),'stderr':normalize(child.stderr,root,binary),'files':files})
        return result


def scenarios():
    return [('claude','{"theme":"dark","apiKey":"drop","max_tokens":4096,"nested":{"authInfo":"drop","safe":true},"hooks":{"Stop":[{"hooks":[{"command":"@HOME@/.claude/tool.sh"},{"command":"/not/there"}]}]},"statusLine":{"command":"/not/there"}}'),
               ('codex','model="gpt-5"\nmax_tokens=4096\napi_key="secret"\n[projects."@HOME@/project"]\ntrust_level="trusted"\n[mcp_servers.demo]\nurl="x"\n[features]\nsafe=true\n'),
               ('pi','{// comment\n"defaultProvider":"openai","token":"drop","safe":"@HOME@/file",}'),
               ('opencode','{"model":"openai/test","mcp":{"x":{"url":"private"}},"safe":true}'),
               ('cursor','{"version":1,"hooks":{"stop":[{"command":"echo safe"}]},"headers":{"Authorization":"secret"}}'),
               ('claude','{"hooks":false}'),('claude','{'),
               ('codex','prompt="""\nline\n[not-a-table]\n"""\n"mcp_servers".key="secret"\n[features]\nrequires_openai_auth=true\n'),
               ('claude','{"statusLine":{"command":"curl https://hooks.slack.com/services/secret"}}')]


def hard_link(root, env):
    """A file under a synced directory whose other name is a file outside every agent's."""
    (root/'private.txt').write_text('hard linked content')
    os.link(root/'private.txt', Path(env['HOME'])/'.claude/skills/custom/notes.md')


def stale_login_record(root, env):
    """A login record from an earlier setup whose workspace id now names the person's own
    workspace, and every dispatched command logged."""
    records=root/'remote/.local/state/telar/setup-logins';records.mkdir(parents=True)
    (records/'claude').write_text('11 12 13\n')
    env.update(FIXTURE_PERSON='1',FIXTURE_ARGV=str(root/'remote-argv.jsonl'))


@contextlib.contextmanager
def machine(binary, agents=('claude',), **fixture):
    """A private home with these agents on PATH, a remote home and the shim as the gateway
    program; `fixture` sets the shim's FIXTURE_* modes."""
    with tempfile.TemporaryDirectory(prefix='telar-setup-', dir='/tmp') as temporary:
        root = Path(temporary).resolve()
        env = environment(root)
        remote = root / 'remote'
        remote.mkdir(mode=0o700)
        bindir = root / 'bin'
        bindir.mkdir()
        install_gateway(bindir, env, SHIM)
        env['SHELL'] = QUIET_LOGIN_SHELL
        for agent in agents:
            (bindir / agent).write_text('#!/bin/sh\nexit 0\n')
            (bindir / agent).chmod(0o700)
        calls = root / 'calls.jsonl'
        env.update(PATH=f'{bindir}:/usr/bin:/bin', FIXTURE_REMOTE_HOME=str(remote), FIXTURE_TELAR=str(binary), FIXTURE_CALLS=str(calls),
                   FIXTURE_SCHEMA='cqp00009' if b'cqp00009' in binary.read_bytes() else '886b480d')
        env.update({'FIXTURE_' + key.upper(): value for key, value in fixture.items()})
        (Path(env['XDG_CONFIG_HOME']) / 'telar').mkdir(exist_ok=True, mode=0o700)

        def run(*words, answers=None):
            """Runs telar; with `answers`, on a terminal that has them typed ahead."""
            if answers is None:
                result = subprocess.run([str(binary), *words], env=env, cwd=root, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
                return result.returncode, result.stdout
            leader, follower = pty.openpty()
            try:
                os.write(leader, answers)
                process = subprocess.Popen([str(binary), *words], env=env, cwd=root, stdin=follower, stdout=follower, stderr=follower, start_new_session=True)
                output = b''
                while process.poll() is None or select.select([leader], [], [], 0)[0]:
                    if select.select([leader], [], [], .05)[0]:
                        output += os.read(leader, 65536)
                return process.wait(timeout=90), output.decode(errors='replace')
            finally:
                os.close(follower)
                os.close(leader)

        def calls_made():
            return [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []

        yield types.SimpleNamespace(root=root, env=env, home=Path(env['HOME']), remote=remote, run=run, calls=calls_made)


def steps(output):
    return {step['step']: step['status'] for step in json.loads(output)['steps']}


SKIP_ALL_BUT_CONFIG = ('--skip', 'agents,login,editor')
SKIP_ALL = ('--skip', 'agents,config,login,editor')


def editor_is_provisioned(binary):
    """Setup has the machine's own telar provision the editor's Neovim, after the agents'
    integrations, unless it is skipped; the machine saying nothing is taken as done."""
    with machine(binary) as fixture:
        status, output = fixture.run('machine', 'setup', FIXTURE, '--skip', 'agents,config,login', '--json')
        notes = [note for step in json.loads(output)['steps'] if step['step'] == 'integrations' for note in step.get('notes', [])]
        assert status == 0 and any(note.startswith('editor: ') for note in notes), output
        before = len(fixture.calls())
    with machine(binary) as fixture:
        status, output = fixture.run('machine', 'setup', FIXTURE, *SKIP_ALL, '--json')
        notes = [note for step in json.loads(output)['steps'] if step['step'] == 'integrations' for note in step.get('notes', [])]
        assert status == 0 and not any(note.startswith('editor: ') for note in notes) and len(fixture.calls()) == before - 1, output


def editor_is_sent(binary):
    """Where this telar's package brought a Neovim and the machine is of the system and the
    processor it is for, setup sends it there, so the machine needs no network for it; a
    machine of another kind fetches its own. The fixture's machine says it is Darwin on arm64."""
    with tempfile.TemporaryDirectory(prefix='telar-package-', dir='/tmp') as temporary:
        package = Path(temporary).resolve()
        (package / 'bin').mkdir()
        packaged = package / 'bin' / 'telar'
        shutil.copy2(binary, packaged)
        nvim = package / 'share/telar/nvim/9.9.9/bin/nvim'
        nvim.parent.mkdir(parents=True)
        nvim.write_text('#!/bin/sh\necho packaged\n')
        nvim.chmod(0o755)
        same = tuple(subprocess.run(['uname', '-sm'], capture_output=True, text=True).stdout.split()) == ('Darwin', 'arm64')
        with machine(packaged) as fixture:
            there = fixture.remote / '.local/share/telar/nvim/9.9.9/bin/nvim'
            for sent in (same, False):
                status, output = fixture.run('machine', 'setup', FIXTURE, '--skip', 'agents,config,login', '--json')
                notes = [note for step in json.loads(output)['steps'] if step['step'] == 'integrations' for note in step.get('notes', [])]
                assert status == 0 and there.exists() == same, output
                # Sent once: a machine that has it is sent nothing.
                assert ("editor: provisioned from this telar's package" in notes) == sent, output
            assert not same or there.read_text() == nvim.read_text()
    with machine(binary) as fixture:
        status, output = fixture.run('machine', 'setup', FIXTURE, '--skip', 'agents,config,login', '--json')
        assert status == 0 and "this telar's package" not in output and not (fixture.remote / '.local/share/telar/nvim').exists(), output


def probe_failures(binary):
    """A probe that prints no platform, as a shell banner does, installs nothing; a probe
    that fails there is a platform failure behind a gateway that admits this machine."""
    with machine(binary, probe='banner') as fixture:
        status, output = fixture.run('machine', 'setup', FIXTURE, *SKIP_ALL, '--json')
        assert status == 1 and steps(output)['platform'] == 'failed', output
        assert len(fixture.calls()) == 1, fixture.calls()
    with machine(binary, probe='exit3') as fixture:
        status, output = fixture.run('machine', 'setup', FIXTURE, *SKIP_ALL, '--json')
        result = steps(output)
        assert status == 1 and (result['gateway'], result['platform']) == ('ok', 'failed'), output


def configuration_sync(binary):
    """What the sync sends and keeps: an oversized file stays here while the rest goes,
    programs a hook names under ~ or $HOME go with it, and a hook to a missing program is
    left out."""
    with machine(binary) as fixture:
        claude = fixture.home / '.claude'
        (claude / 'skills/big').mkdir(parents=True)
        (claude / 'skills/big/huge.md').write_bytes(b'x' * (1024 * 1024 + 1))
        (claude / 'skills/small').mkdir()
        (claude / 'skills/small/SKILL.md').write_text('small\n')
        (claude / 'hooks').mkdir()
        for name in ('run.sh', 'other.sh'):
            (claude / 'hooks' / name).write_text('#!/bin/sh\nexit 0\n')
            (claude / 'hooks' / name).chmod(0o755)
        hooks = [{'command': '~/.claude/hooks/run.sh'}, {'command': '$HOME/.claude/hooks/other.sh --flag'}, {'command': '~/.claude/hooks/missing.sh'}]
        (claude / 'settings.json').write_text(json.dumps({'hooks': {'Stop': [{'hooks': hooks}]}}))
        status, output = fixture.run('machine', 'setup', FIXTURE, *SKIP_ALL_BUT_CONFIG, '--json')
        assert status == 0 and steps(output)['configuration'] == 'changed', output
        sent = fixture.remote / '.claude'
        assert (sent / 'skills/small/SKILL.md').exists() and not (sent / 'skills/big/huge.md').exists(), output
        assert (sent / 'hooks/run.sh').exists() and (sent / 'hooks/other.sh').exists(), output
        settings = (sent / 'settings.json').read_text()
        assert 'hooks/run.sh' in settings and 'hooks/other.sh' in settings and 'missing.sh' not in settings, settings


def agents_from_login_shell(binary):
    """An agent this process's PATH misses, as a window started from the desktop runs setup,
    is found in the PATH the person's login shell sets, and setup brings its settings there."""
    with machine(binary, agents=()) as fixture:
        installed = fixture.home / 'agents'
        installed.mkdir()
        (installed / 'claude').write_text('#!/bin/sh\nexit 0\n')
        (installed / 'claude').chmod(0o700)
        (fixture.home / '.profile').write_text('echo a greeting from the startup files\nPATH="$HOME/agents:$PATH"\nexport PATH\n')
        # A login shell that reads the person's profile alone, not the system's.
        shell = fixture.root / 'login-shell'
        shell.write_text('#!/bin/sh\n[ "$1 $2" = "-l -c" ] || exit 2\n. "$HOME/.profile"\nexec /bin/sh -c "$3"\n')
        shell.chmod(0o700)
        fixture.env['SHELL'] = str(shell)
        (fixture.home / '.claude').mkdir()
        (fixture.home / '.claude/settings.json').write_text('{"theme":"dark"}')
        status, output = fixture.run('machine', 'setup', FIXTURE, *SKIP_ALL_BUT_CONFIG, '--json')
        assert status == 0 and steps(output)['configuration'] == 'changed', output
        assert (fixture.remote / '.claude/settings.json').exists(), output


def telar_skill_kept_there(binary):
    """telar's own skill there belongs to the telar installed there: the copy of another
    build here is not sent over it."""
    with machine(binary) as fixture:
        local = fixture.home / '.claude/skills/telar/SKILL.md'
        local.parent.mkdir(parents=True)
        local.write_text('telar skill of this build\n')
        theirs = fixture.remote / '.claude/skills/telar/SKILL.md'
        theirs.parent.mkdir(parents=True)
        theirs.write_text('telar skill of the remote build\n')
        status, output = fixture.run('machine', 'setup', FIXTURE, *SKIP_ALL_BUT_CONFIG, '--json')
        assert status == 0 and theirs.read_text() == 'telar skill of the remote build\n', output


def binary_upload(binary):
    """--binary installs this build there, telar and its runtime, config checker and gateway
    byte for byte, verified there against their digests; a second setup finds them and sends
    nothing. Every remote script runs in the remote home."""
    with machine(binary, real='1') as fixture:
        build = fixture.root / 'build'
        build.mkdir()
        names = ('telar', 'telar-runtime', 'telar-config-check', 'telar-gateway')
        for name in names:
            shutil.copy2(binary.parent / name, build / name)
        status, output = fixture.run('machine', 'setup', FIXTURE, '--binary', str(build / 'telar'), *SKIP_ALL, '--json')
        assert status == 0 and steps(output)['telar'] == 'changed', output
        installed = Path(next(step['detail'] for step in json.loads(output)['steps'] if step['step'] == 'telar').split(' at ', 1)[1]).parent
        for name in names:
            assert (installed / name).read_bytes() == (build / name).read_bytes(), name
        before = len(fixture.calls())
        status, output = fixture.run('machine', 'setup', FIXTURE, '--binary', str(build / 'telar'), *SKIP_ALL, '--json')
        assert status == 0 and steps(output)['telar'] == 'ok', output
        uploads = [call for call in fixture.calls()[before:] if call['argv'][-1].startswith('exec /bin/sh -c ')]
        assert not uploads, uploads


CODEX_DEVICE_SCREEN = """Welcome to Codex [v0.46.0]
OpenAI's command-line coding agent

Follow these steps to sign in with ChatGPT using device code authorization:

1. Open this link in your browser and sign in to your account
   https://auth.openai.com/codex/device

2. Enter this one-time code (expires in 15 minutes)
   ABCD-EFGH9

Device codes are a common phishing target. Never share this code.
"""


def logins(binary):
    """Each agent's login there: codex shows its device page and code here, OpenCode logs in
    only for an OpenAI model, Pi only with a provider, and a code pasted here reaches the
    login pane while an empty answer sends nothing."""
    with machine(binary, agents=('codex',), login='pending', there='codex', pane_text=CODEX_DEVICE_SCREEN) as fixture:
        status, output = fixture.run('machine', 'setup', FIXTURE, '--skip', 'agents,config,editor')
        assert 'https://auth.openai.com/codex/device' in output and 'ABCD-EFGH9' in output, output
    for model, opened in (('openai/gpt-5', 1), ('anthropic/claude', 0)):
        with machine(binary, agents=('opencode', 'pi'), login='pending', there='opencode,pi') as fixture:
            fixture.env['FIXTURE_ARGV'] = str(fixture.root / 'argv.jsonl')
            (Path(fixture.env['XDG_CONFIG_HOME']) / 'opencode').mkdir()
            (Path(fixture.env['XDG_CONFIG_HOME']) / 'opencode/opencode.json').write_text(json.dumps({'model': model}))
            (fixture.home / '.pi/agent').mkdir(parents=True)
            (fixture.home / '.pi/agent/settings.json').write_text('{}')
            status, output = fixture.run('machine', 'setup', FIXTURE, '--skip', 'agents,config,editor', '--json')
            argv = fixture.root / 'argv.jsonl'
            commands = [json.loads(line) for line in argv.read_text().splitlines()] if argv.exists() else []
            assert [words[:2] for words in commands].count(['workspace', 'create']) == opened, (model, commands)
            assert steps(output)['logins'] != 'failed', output
    for answer, sent in ((b'my-code-123\n', ['my-code-123']), (b'\n', [])):
        with machine(binary, login='paste') as fixture:
            log = fixture.root / 'sent.jsonl'
            fixture.env['FIXTURE_SENT'] = str(log)
            status, output = fixture.run('machine', 'setup', FIXTURE, '--skip', 'agents,config,editor', answers=answer)
            texts = [json.loads(line)['text'].strip() for line in log.read_text().splitlines()] if log.exists() else []
            assert texts == sent, (answer, texts, output)


def agent_installs(binary):
    """Setup installs an agent missing there with its official installer only when the
    machine has what that installer needs, and never reinstalls one already there."""
    with machine(binary, agents=('claude', 'codex', 'pi'), scripts='real') as fixture:
        fetched = fixture.root / 'fetched'
        fixture.env['FIXTURE_PROBE_EXTRA'] = f'tool=curl\ntool=tar\ntool=bash\nagent=claude:{fixture.remote}/claude'
        # curl there "downloads" an installer that records which one ran.
        curl = fixture.remote / '.local/bin/curl'
        curl.parent.mkdir(parents=True)
        curl.write_text('#!/bin/sh\nfor word; do case "$word" in https://*) url=$word;; esac; previous=$word; done\n'
                        'while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done\n'
                        f'printf \'#!/bin/sh\\necho %s >> "{fetched}"\\n\' "$url" > "$out"\n')
        curl.chmod(0o700)
        status, output = fixture.run('machine', 'setup', FIXTURE, '--skip', 'config,login,editor', '--json')
        assert steps(output)['agents'] == 'changed', output
        assert fetched.read_text().split() == ['https://chatgpt.com/codex/install.sh'], fetched.read_text()


def refused_sync(binary):
    """A machine that refuses the sync fails the configuration step and setup."""
    with machine(binary, receive='fail') as fixture:
        (fixture.home / '.claude').mkdir()
        (fixture.home / '.claude/settings.json').write_text('{"theme":"dark"}')
        status, output = fixture.run('machine', 'setup', FIXTURE, *SKIP_ALL_BUT_CONFIG, '--json')
        assert status == 1 and steps(output)['configuration'] == 'failed', output


def codex_hooks(binary):
    """Codex hooks synced there call the telar installed there, beside the person's own."""
    with machine(binary, agents=('codex',)) as fixture:
        (fixture.home / '.codex').mkdir()
        (fixture.home / '.codex/hooks.json').write_text(json.dumps({'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'echo mine'}]}]}}))
        status, output = fixture.run('machine', 'setup', FIXTURE, *SKIP_ALL_BUT_CONFIG, '--json')
        assert status == 0, output
        synced = (fixture.remote / '.codex/hooks.json').read_text()
        program = str(fixture.remote / '.local/share/telar/versions' / VERSION / 'telar')
        assert 'echo mine' in synced and json.dumps(program)[1:-1] in synced and str(binary) not in synced, synced


def add_then_setup(binary):
    """`machine add --setup` saves the machine and sets it up; `--check` saves a machine
    that answers."""
    with machine(binary) as fixture:
        status, output = fixture.run('machine', 'add', 'box', address('box'), '--setup', *SKIP_ALL, '--json')
        assert status == 0 and steps(output)['gateway'] == 'ok', output
        status, output = fixture.run('machine', 'add', 'new', address('new'), '--check')
        assert status == 0, output
        _, listed = fixture.run('machine', 'list', '--json')
        assert {row['label'] for row in json.loads(listed)['machines']} == {'box', 'new'}, listed


def terminal_answers(binary):
    """On a terminal, --confirm changes nothing without a yes, and a runtime of another
    build there is stopped only after one."""
    with machine(binary) as fixture:
        status, output = fixture.run('machine', 'setup', FIXTURE, '--confirm', *SKIP_ALL, answers=b'no\n')
        assert status == 0 and 'Nothing was changed' in output and not fixture.calls(), output
        status, output = fixture.run('machine', 'setup', FIXTURE, '--confirm', *SKIP_ALL, answers=b'yes\n')
        assert status == 0 and fixture.calls(), output
    for answer, expected in ((b'\n', False), (b'n\n', False), (b'y\n', True)):
        with machine(binary, endpoint='mismatch', scripts='real') as fixture:
            telar = fixture.remote / '.local/bin/telar'
            telar.parent.mkdir(parents=True)
            telar.write_text(f'#!/bin/sh\n[ "$1 $2" = "server stop" ] && touch "{fixture.remote}/stopped" && echo "telar runtime is stopping"\n')
            telar.chmod(0o700)
            status, output = fixture.run('machine', 'setup', FIXTURE, *SKIP_ALL, answers=answer)
            assert (fixture.remote / 'stopped').exists() == expected and (status == 0) == expected, (answer, status, output)


def pairing(binary):
    """A gateway that does not admit this machine fails setup at its first step, with nothing
    enrolled or saved. A pairing address enrolls this machine once, under its own name; what
    is saved, and what every command there is sent to, is the address without the code."""
    with machine(binary, auth='once') as fixture:
        status, output = fixture.run('machine', 'setup', FIXTURE, *SKIP_ALL, '--json')
        assert status == 1 and steps(output) == {'gateway': 'failed'}, output
        assert [call['argv'][0] for call in fixture.calls()] == ['run'], fixture.calls()
        listed = json.loads(fixture.run('machine', 'list', '--json')[1])
        assert not listed['machines'], listed
        status, output = fixture.run('machine', 'setup', PAIRING, *SKIP_ALL, '--json')
        assert status == 0 and steps(output)['gateway'] == 'ok', output
        calls = [call['argv'] for call in fixture.calls()]
        assert [argv for argv in calls if argv[0] == 'enroll'] == [['enroll', PAIRING, '--name', listed['local']]], calls
        assert {argv[-2] for argv in calls if argv[0] == 'run'} == {FIXTURE}, calls
        saved = json.loads(fixture.run('machine', 'list', '--json')[1])['machines']
        assert [(row['label'], row['destination']) for row in saved] == [('fixture', FIXTURE)], saved
    with machine(binary, auth='once') as fixture:
        status, output = fixture.run('machine', 'add', 'box', PAIRING, '--check')
        calls = [call['argv'] for call in fixture.calls()]
        # Pairing, then the check's discovery and its question about the machine's editor.
        assert status == 0 and [argv[0] for argv in calls] == ['enroll', 'run', 'run'] and calls[1][-2] == FIXTURE and calls[2][-1].endswith('integration status editor'), (status, output, calls)
        saved = json.loads(fixture.run('machine', 'list', '--json')[1])['machines']
        assert [(row['label'], row['destination']) for row in saved] == [('box', FIXTURE)], saved


def spent_pairing_codes(binary):
    """A code is spent only on a machine setup goes on to save: a --binary without its
    companions refuses before it pairs, and a machine paired before a later step fails is
    saved, so setting it up again by its label goes on from there."""
    with machine(binary, auth='once') as fixture:
        build = fixture.root / 'build'
        build.mkdir()
        shutil.copy2(binary, build / 'telar')
        status, _ = fixture.run('machine', 'setup', PAIRING, '--binary', str(build / 'telar'), *SKIP_ALL, '--json')
        assert status == 1 and not [call for call in fixture.calls() if call['argv'][0] == 'enroll'], fixture.calls()
    with machine(binary, auth='once', probe='exit3') as fixture:
        status, output = fixture.run('machine', 'setup', PAIRING, *SKIP_ALL, '--json')
        gateway = next(step for step in json.loads(output)['steps'] if step['step'] == 'gateway')
        assert status == 1 and steps(output)['platform'] == 'failed' and any('pairing code is spent' in note for note in gateway['notes']), output
        saved = json.loads(fixture.run('machine', 'list', '--json')[1])['machines']
        assert [(row['label'], row['destination']) for row in saved] == [('fixture', FIXTURE)], saved
        status, output = fixture.run('machine', 'setup', 'fixture', *SKIP_ALL, '--json')
        assert steps(output)['gateway'] == 'ok', output


def runtime_failure_keeps_telar(binary):
    """A runtime that does not start there leaves the build it was to run saved: the profile
    names the telar setup placed."""
    with machine(binary, endpoint='mismatch') as fixture:
        status, output = fixture.run('machine', 'setup', FIXTURE, *SKIP_ALL, '--json')
        assert status == 1 and steps(output)['runtime'] == 'failed' and steps(output)['profile'] == 'changed', output
        saved = json.loads(fixture.run('machine', 'list', '--json')[1])['machines']
        assert [row.get('telar_path') for row in saved] == [str(fixture.remote / '.local/share/telar/versions' / VERSION / 'telar')], saved


def events(binary):
    """--events writes one JSON line per step, note and question as it happens, and a done event
    with the report --json prints. A question is answered with one JSON line on standard input;
    an answer to another question, or none, is no."""
    with machine(binary) as fixture:
        child = subprocess.run([str(binary), 'machine', 'setup', FIXTURE, *SKIP_ALL, '--events'], env=fixture.env, cwd=fixture.root, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
        lines = [json.loads(line) for line in child.stdout.splitlines()]
        assert child.returncode == 0 and lines[-1]['event'] == 'done' and lines[-1]['report']['ready'], child.stdout
        streamed = [line['step'] for line in lines if line['event'] == 'step']
        assert streamed[:2] == ['gateway', 'platform'] and streamed == [step['step'] for step in lines[-1]['report']['steps']], streamed
    answers = (
        ('{"answer":"stop_runtime","value":true}\n', True),
        ('{"answer":"stop_runtime","value":false}\n', False),
        ('{"answer":"confirm","value":true}\n', False),
        ('', False),
    )
    for answer, stopped in answers:
        with machine(binary, endpoint='mismatch', scripts='real') as fixture:
            telar = fixture.remote / '.local/bin/telar'
            telar.parent.mkdir(parents=True)
            telar.write_text(f'#!/bin/sh\n[ "$1 $2" = "server stop" ] && touch "{fixture.remote}/stopped" && echo "telar runtime is stopping"\n')
            telar.chmod(0o700)
            child = subprocess.run([str(binary), 'machine', 'setup', FIXTURE, *SKIP_ALL, '--events'], env=fixture.env, cwd=fixture.root, input=answer, capture_output=True, text=True, timeout=90)
            lines = [json.loads(line) for line in child.stdout.splitlines()]
            questions = [line for line in lines if line['event'] == 'question']
            assert [question['kind'] for question in questions] == ['stop_runtime'], child.stdout
            assert (fixture.remote / 'stopped').exists() == stopped and (child.returncode == 0) == stopped, (answer, child.stdout)


def contracts(binary):
    """Setup contracts asserted on their effects alone, beside the recorded outputs."""
    events(binary)
    spent_pairing_codes(binary)
    agents_from_login_shell(binary)
    runtime_failure_keeps_telar(binary)
    probe_failures(binary)
    editor_is_provisioned(binary)
    editor_is_sent(binary)
    configuration_sync(binary)
    refused_sync(binary)
    codex_hooks(binary)
    add_then_setup(binary)
    terminal_answers(binary)
    pairing(binary)
    binary_upload(binary)
    logins(binary)
    agent_installs(binary)
    # Red on the current code: the sync sends this build's skill over the remote one.
    telar_skill_kept_there(binary)
    for result in run(binary,'claude','{}',prepare=hard_link):
        files=result['files']
        assert 'remote/.claude/skills/custom/SKILL.md' in files, sorted(files)
        assert 'remote/.claude/skills/custom/notes.md' not in files and not any('hard linked content' in entry.get('text','') for name,entry in files.items() if name.startswith('remote/')), sorted(files)
    first,_=run(binary,'claude','{}',login='ended',prepare=stale_login_record)
    commands=[json.loads(line) for line in first['files']['remote-argv.jsonl']['text'].splitlines()]
    assert ['tab','close','12','--workspace','11','--json'] not in commands, commands
    assert [words[:2] for words in commands].count(['workspace','create'])==1, commands
    return 18
