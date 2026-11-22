#!/usr/bin/env python3
"""Check machine files, argv dispatch, CLI links and startup validation in private homes."""
import base64
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import subprocess
import socket
import tempfile

# The version this checkout builds, which a fixture's remote reports as installed.
VERSION = (Path(__file__).resolve().parents[3] / 'VERSION').read_text().split()[0]

# The file that stands in for telar-gateway, the program telar runs to reach a machine. telar
# finds it through TELAR_GATEWAY_PROGRAM, and no snapshot records it.
GATEWAY = 'gateway-stand-in'
KEY = '00112233445566778899aabbccddeeff' * 2

# How a stand-in written in Python starts: with telar-gateway's command line as telar writes it,
# `run [-t] [--to ADDRESS] ADDRESS COMMAND` or `enroll ADDRESS --name NAME`, read into `request`.
# Any other is the usage error it is to the program.
GATEWAY_ARGV = r'''#!/usr/bin/env python3
import sys
def gateway_request(words):
 verb,rest=(words[0] if words else ''),words[1:]
 if verb=='enroll' and len(rest)==3 and rest[1]=='--name':
  return {'verb':verb,'destination':rest[0],'name':rest[2],'command':''}
 terminal=rest[:1]==['-t']
 rest=rest[terminal:]
 named=rest[1] if rest[:1]==['--to'] and len(rest)>1 else None
 if named:rest=rest[2:]
 if verb!='run' or len(rest)!=2:
  print('stand-in gateway: unexpected arguments',words,file=sys.stderr);sys.exit(2)
 return {'verb':verb,'terminal':terminal,'destination':named or rest[0],'command':rest[1]}
request=gateway_request(sys.argv[1:])
command=request['command']
'''

# The same for a stand-in written for /bin/sh, which answers every `run` alike.
GATEWAY_RUN = '#!/bin/sh\n[ "$1" = run ] || { echo "stand-in gateway: unexpected arguments: $*" >&2; exit 2; }\n'

# What the program says, with status 255, of a gateway whose key is not the one its address pins,
# and of one that does not admit this machine.
ANOTHER_KEY = 'telar gateway: The gateway holds another key than the one its address pins'
NOT_PAIRED = 'telar gateway: this machine is not paired with that gateway; pair it again with `telar machine add`'


def address(host):
    """The address the gateway of `host` is saved under."""
    return f'telar://{host}:8352#{KEY}'


def install_gateway(directory, env, text):
    """Puts `text` in `directory` as the program every telar run with `env` reaches machines through."""
    program = directory / GATEWAY
    program.write_text(text)
    program.chmod(0o700)
    env['TELAR_GATEWAY_PROGRAM'] = str(program)


def environment(root):
    result = {k: v for k, v in os.environ.items()
              if not k.startswith(('TELAR_', 'XDG_')) and k not in
              ('CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'PI_CODING_AGENT_DIR', 'CURSOR_CONFIG_DIR')}
    for key, directory in [('HOME', 'home'), ('TMPDIR', 'tmp'), ('XDG_RUNTIME_DIR', 'run'),
                           ('XDG_DATA_HOME', 'data'), ('XDG_CONFIG_HOME', 'config'), ('XDG_STATE_HOME', 'state')]:
        path = root / directory
        path.mkdir(exist_ok=True, mode=0o700)
        result[key] = str(path)
    result['TELAR_SOCKET'] = str(root / 'runtime.sock')
    result['SHELL'] = '/bin/sh'
    result['PYTHONDONTWRITEBYTECODE'] = '1'
    return result


def normalize(value, root, binary):
    if isinstance(value, str):
        value = value.replace(str(binary), '@EXECUTABLE@').replace(str(root), '@ROOT@')
        value = re.sub(r'm-[0-9a-f]{12}', 'm-@ID@', value)
        value = value.replace(socket.gethostname(), '@HOSTNAME@')
        value = value.replace('886b480d', '@SCHEMA@').replace('cqp00008', '@SCHEMA@')
        value = value.replace(f'telar {VERSION}', 'telar @VERSION@').replace(f'versions/{VERSION}', 'versions/@VERSION@')
        return value
    return value


def snapshot(root, binary):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            result[str(path.relative_to(root))] = {'link': normalize(os.readlink(path), root, binary)}
        elif path.is_file() and path.name != GATEWAY:
            data = normalize(path.read_bytes().decode('utf-8', errors='backslashreplace'), root, binary)
            result[str(path.relative_to(root))] = {'text': data, 'mode': path.stat().st_mode & 0o777}
    return result


def invoke(binary, root, env, args, data=b''):
    result = subprocess.run([str(binary), *args], input=data, capture_output=True, env=env, cwd=root, timeout=15)
    return {'status': result.returncode, 'stdout': normalize(result.stdout.decode(errors='backslashreplace'), root, binary),
            'stderr': normalize(result.stderr.decode(errors='backslashreplace'), root, binary), 'files': snapshot(root, binary)}


def encode(word):
    return 'a' + base64.urlsafe_b64encode(word.encode()).decode().rstrip('=')


def outcomes(binary):
    cases = []
    with tempfile.TemporaryDirectory(prefix='telar-machines-', dir='/tmp') as temporary:
        root = Path(temporary).resolve()
        env = environment(root)
        profiles = root / 'config/telar/machines.json'
        profiles.parent.mkdir(mode=0o700)
        def run(name, args, data=b''):
            result = invoke(binary, root, env, args, data)
            cases.append({'name': normalize(name, root, binary), **result})
            return result
        def run_terminal(name, args, streams):
            leader, follower = pty.openpty()
            try:
                result = subprocess.run([str(binary), *args], stdin=follower,
                                        stdout=follower if 'stdout' in streams else subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env, cwd=root, timeout=15)
                # Drain while the follower is still open: closing it can drop what is queued.
                output = result.stdout or b''
                while select.select([leader], [], [], 0)[0]:
                    output += os.read(leader, 65536)
            finally:
                os.close(follower)
                os.close(leader)
            cases.append({'name': name, 'status': result.returncode,
                          'stdout': normalize(output.decode(errors='backslashreplace').replace('\r\n', '\n'), root, binary),
                          'stderr': normalize(result.stderr.decode(errors='backslashreplace'), root, binary),
                          'files': snapshot(root, binary)})
        host, other = address('host'), address('other')
        for args in [[], ['wat'], ['add'], ['add', 'box'], ['check'], ['receive-config', 'extra'], ['list', '--socket', '/x'],
                     ['add','box',host,'--color'], ['add','box',host,'--color','red','--color','blue'],
                     ['add','box',host,'--binary','x'], ['add','box',host,'--skip','agents'],
                     ['setup','box','--skip','wat'], ['setup','box','--binary'], ['remove','box','--json']]:
            run('validation-machine-' + repr(args), ['machine', *args])
        for args in [[], ['wat'], ['install','--dir'], ['status','--json'], ['status','--dir','a','--dir','b']]:
            run('validation-cli-' + repr(args), ['cli', *args])
        for args in [['--machine'], ['--machine='], ['--theme'], ['--theme='], ['--theme','wat'],
                     ['--profile'], ['--config='], ['--remote='], ['--no-config','--profile','a'],
                     ['--theme','shade','--theme','vesper'], ['--fresh','--fresh'],
                     ['--fresh','--remote','x'], ['--remote','x','--machine','y'], ['--'],
                     ['gui','--no-config','--config','x'], ['gui','--profile='], ['gui','--remote','x','--remote','y']]:
            run('validation-launch-' + repr(args), args)
        env['SSH_CONNECTION'] = 'fixture connection'
        for words in [[], ['gui'], ['/bin/echo','literal'], ['--machine','box'], ['--remote',host]]:
            run('no-display-'+repr(words), words)
        del env['SSH_CONNECTION']
        run('empty-list', ['machine','list'])
        run('empty-list-json', ['machine','list','--json'])
        # What is not a gateway's address names no machine, an SSH destination included.
        for label,destination,color in [('bad label',host,None), ('box','-option',None), ('box','bad host',None), ('box','dev@host',None),
                                        ('box',host,'not a color')]:
            run('invalid-fields-' + label + destination, ['machine','add',label,destination] + (['--color',color] if color else []))
        run('add', ['machine','add','box',host,'--color','#aBc123'])
        run('duplicate-label', ['machine','add','box',other])
        run('duplicate-destination', ['machine','add','gpu',host])
        run('second-machine', ['machine','add','gpu',other,'--disabled'])
        run('list', ['machine','list'])
        run('list-json', ['machine','list','--json'])
        for action in ['disable','disable','enable','enable']:
            run(action, ['machine',action,'box'])
        run('rename', ['machine','rename','box','renamed'])
        run('same-rename', ['machine','rename','renamed','renamed'])
        run('taken-rename', ['machine','rename','renamed','gpu'])
        run('remove', ['machine','remove','gpu'])
        run('remove-missing', ['machine','remove','gpu'])
        profiles.chmod(0o644)
        run('insecure-file', ['machine','list'])
        profiles.chmod(0o600)
        fixture = {'version':2,'local_label':'local','machines':[{'id':'m-0123456789ab','label':'box','destination':host,
                   'telar_path':'/opt/telar','enabled':False,'logins':{'claude':'done','codex':'pending','pi':'failed'}}]}
        profiles.write_text(json.dumps(fixture))
        run('extended-list', ['machine','list'])
        run('extended-list-json', ['machine','list','--json'])
        run('local-collision', ['machine','add','local',other])
        run('local-dispatch', ['--machine','local','--version'])
        run('local-dispatch-equals', ['--machine=local','machine','list','--json'])
        run('local-dispatch-validation', ['--machine','local','machine','wat'])
        run('decoded-validation', ['dispatch-argv',encode('machine'),encode('wat')])
        run('unknown-dispatch-validation', ['--machine','unknown','machine','wat'])
        run('unknown-cli-validation', ['--machine','unknown','cli','wat'])
        run('unknown-gui-validation', ['--machine','unknown','gui','--profile'])
        run('unknown-window-machine', ['--machine','unknown','--no-config'])
        run('unknown-dispatch', ['--machine','unknown','--version'])
        run('nested-dispatch', ['--machine','box','--machine','other','--version'])
        run('nested-dispatch-argv', ['--machine','box','dispatch-argv', encode('--version')])
        run('machine-help-local', ['--machine','unknown','machine','list','--help'])
        for words in [['--version'], ['machine','list','--json'], ['cli','status','--dir',str(root/'bin with spaces')]]:
            run('decode-'+repr(words), ['dispatch-argv', *map(encode,words)])
        for word in ['bad', '', 'aA', 'aAA', 'a====', 'aZh']:
            run('invalid-decode-'+word, ['dispatch-argv',word])
        bindir=root/'bin';bindir.mkdir()
        # The gateway program's whole command line is what dispatch promises: `run`, the terminal
        # flag, the machine's address and the command there, in that order.
        install_gateway(bindir, env, '#!/bin/sh\nprintf "%s\\n" "$@"\nexit 37\n')
        env['PATH']=str(bindir)+':/usr/bin:/bin'
        # The isolated profile is disabled: dispatch still explicitly selects it.
        run('gateway-forward', ['--machine','box','cli','status','--dir',"space ' quote $(touch nope);\nline"])
        # A person at a terminal gets one there, so a remote removal can ask them;
        # a terminal on stdin alone keeps stdout clean of the remote terminal's \r\n.
        for name, streams in [('gateway-forward-terminal', ('stdin', 'stdout')), ('gateway-forward-terminal-stdin', ('stdin',))]:
            run_terminal(name, ['--machine','box','worktree','remove','branch','--force'], streams)
        schema = 'cqp00008' if b'cqp00008' in binary.read_bytes() else '886b480d'
        fixtures = [
            ('reachable', f'printf "%s\\n" "$HOME" /bin/sh "{root}/remote.sock" {schema}\n'),
            ('incompatible', f'printf "%s\\n" "$HOME" /bin/sh "{root}/remote.sock" deadbeef\n'),
            ('unreadable', 'printf "startup banner\\n"\n'),
            ('missing', 'echo "sh: telar: command not found" >&2\nexit 127\n'),
            ('host-key', f"echo '{ANOTHER_KEY}' >&2\nexit 255\n"),
            ('auth', f"echo '{NOT_PAIRED}' >&2\nexit 255\n"),
            ('runtime-mismatch', 'echo "telar protocol mismatch" >&2\nexit 1\n')]
        for label, body in fixtures:
            install_gateway(bindir, env, GATEWAY_RUN + body)
            run('check-' + label, ['machine','check','box'])
            run('check-json-' + label, ['machine','check','box','--json'])
        run('check-unknown', ['machine','check','missing','--json'])
        install_gateway(bindir, env, GATEWAY_RUN + f"echo '{NOT_PAIRED}' >&2\nexit 255\n")
        run('setup-gateway-failure', ['machine','setup','box','--json'])
        run('add-check-failure', ['machine','add','new',address('newhost'),'--check','--json'])
        # A saved machine's address is that machine, a new address takes its name from --label,
        # and an SSH destination is no machine to set up.
        for args in [['setup',host,'--confirm','--json'], ['setup',address('new'),'--label','fresh','--confirm'],
                     ['setup','ssh://dev@new:22','--label','fresh','--confirm'], ['setup',host,'--binary',str(root/'missing')]]:
            run('setup-'+repr(args), ['machine',*args])
        # A deterministic gateway exercises setup effects without downloads
        # or writes on a real remote account. Only the transport is substituted.
        shim = GATEWAY_ARGV + "import os,shlex\n"
        shim += "schema=" + repr(schema) + "\n"
        shim += "if command.endswith(\"server endpoint'\"):\n print(os.environ['HOME']);print('/bin/sh');print(os.environ['HOME']+'/remote.sock');print(schema)\n"
        shim += "else:\n script=sys.stdin.read()\n if script.startswith('dir='):\n  directory=shlex.split(script.splitlines()[0].split('=',1)[1])[0]\n  print('os=Darwin\\narch=arm64\\nlibc=gnu\\nhome='+os.environ['HOME'])\n  print('target='+os.environ['HOME']+'/.local/share/telar/versions/'+directory+'/telar')\n  print('installed=telar " + VERSION + "')\n elif 'link=$HOME/.local/bin/telar' in script:print('linked')\n"
        install_gateway(bindir, env, shim)
        for words in [['setup','box','--json'], ['setup','box','--json'], ['setup','box','--skip','agents,config,login','--json'],
                      ['setup',address('new-destination'),'--label','new-machine','--json']]:
            run('setup-ready-'+repr(words), ['machine',*words])
        install_dir=root/'cli-bin';install_dir.mkdir()
        for action in ['status','uninstall','install','install','status','uninstall','status']:
            run('cli-'+action,['cli',action,'--dir',str(install_dir)])
        (install_dir/'telar').write_text('foreign')
        for action in ['status','install','uninstall']:
            run('cli-foreign-'+action,['cli',action,'--dir',str(install_dir)])
        (install_dir/'telar').unlink()
        run('cli-missing-parent',['cli','install','--dir',str(root/'missing-dir')])
        for data in [b'bad\n', b'telar-config 1\nend\n', b'telar-config 1\nfile 600 1 .claude/a\nx\nend\n',
                     b'telar-config 1\nfile 644 1048577 .claude/a\n', b'telar-config 1\nfile 644 1 .claude/a\nx!',
                     b'telar-config 1\nfile 644 0 .claude/a\n\nend\n']:
            run('receive-'+repr(data),['machine','receive-config'],data)
        for number, data in [('0_0',b''),('-0',b''),('+0',b''),('1__0',b'0123456789'),('_0',b''),('0_',b''),('-1',b'x')]:
            payload=b'telar-config 1\nfile 644 '+number.encode()+b' .claude/numeric\n'+data+b'\nend\n'
            run('receive-number-'+number,['machine','receive-config'],payload)
        def stream(paths):
            return b'telar-config 1\n'+b''.join(f'file {mode} {len(data)} {path}\n'.encode()+data+b'\n' for path,mode,data in paths)+b'end\n'
        paths=[('.claude/settings.json',644,b'{}'),('.codex/tool.sh',755,b'#!/bin/sh\necho hi'),
               ('.claude/../escape',644,b'no'),('.codex/auth.json',644,b'secret'),('.agents/skills/skill/SKILL.md',644,b'hello'),
               ('.codex/sessions/a.txt',644,b'no'),('.claude/keys.pem',644,b'no'),('.cursor/.hidden',644,b'no'),
               ('.config/opencode/plugins/a.ts',644,b'let a=1;')]
        run('receive-files',['machine','receive-config'],stream(paths))
        run('receive-unchanged',['machine','receive-config'],stream(paths))
        outside=root/'outside';outside.mkdir()
        (root/'home/.claude/link').symlink_to(outside,target_is_directory=True)
        (root/'home/.claude/symlink').symlink_to(outside/'file')
        run('receive-symlinks',['machine','receive-config'],stream([('.claude/link/a',644,b'no'),('.claude/symlink',644,b'no')]))
        for raw in ['{','{}','{"version":3,"machines":[]}', '{"version":1,"machines":[],"extra":0}']:
            profiles.write_text(raw)
            run('profiles-invalid-'+raw,['machine','list','--json'])
    return cases


INCOMPATIBLE_SHIM = GATEWAY_ARGV + r'''import os,subprocess
home=os.environ['FIXTURE_REMOTE_HOME']
if command.endswith("server endpoint'"):
 print('telar protocol mismatch',file=sys.stderr);sys.exit(1)
script=sys.stdin.read()
if script.startswith('dir='):
 print('os=Darwin\narch=arm64\nlibc=gnu\nhome='+home)
 print('target='+home+'/.local/share/telar/versions/0.0.0/telar')
 print('installed=telar 0.0.0')
elif 'link=$HOME/.local/bin/telar' in script:print('linked')
else:sys.exit(subprocess.run(['/bin/sh','-s'],input=script,text=True,env=dict(os.environ,HOME=home)).returncode)
'''.replace('0.0.0', VERSION)


def incompatible_runtime_kept(binary):
    """Another build's runtime there keeps running when setup has no person to agree to stop
    it: stopping it ends every pane and agent it runs."""
    with tempfile.TemporaryDirectory(prefix='telar-machines-', dir='/tmp') as temporary:
        root = Path(temporary).resolve()
        env = environment(root)
        bindir = root / 'bin'
        bindir.mkdir()
        install_gateway(bindir, env, INCOMPATIBLE_SHIM)
        remote = root / 'remote'
        log = root / 'stopped'
        # The remote telar a stop would run; it logs what it was asked.
        (remote / '.local/bin').mkdir(parents=True)
        (remote / '.local/bin/telar').write_text(f'#!/bin/sh\necho "$@" >> "{log}"\necho "telar runtime is stopping"\n')
        (remote / '.local/bin/telar').chmod(0o700)
        env.update(PATH=f'{bindir}:/usr/bin:/bin', FIXTURE_REMOTE_HOME=str(remote))
        subprocess.run([str(binary), 'machine', 'add', 'box', address('host')], env=env, cwd=root, check=True, capture_output=True, timeout=15)
        for flags in (['--json'], []):
            result = subprocess.run([str(binary), 'machine', 'setup', 'box', '--skip', 'agents,config,login', *flags], env=env, cwd=root,
                                    stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
            assert result.returncode != 0 and not log.exists(), (flags, result, log.exists() and log.read_text())
            if flags:
                steps = {step['step']: step['status'] for step in json.loads(result.stdout)['steps']}
                assert steps['runtime'] == 'failed', steps


def concurrent_edits(binary):
    """Machines added or removed at once all count: each edit rewrites the whole file. A
    lost update shows only when two edits interleave, so rounds of them race, each filling
    the file to its 16 machines and emptying it."""
    with tempfile.TemporaryDirectory(prefix='telar-machines-', dir='/tmp') as temporary:
        root = Path(temporary).resolve()
        env = environment(root)

        def race(commands):
            processes = [subprocess.Popen([str(binary), 'machine', *words], env=env, cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                         for words in commands]
            statuses = [(process.wait(timeout=30), process.stderr.read()) for process in processes]
            assert all(status == 0 for status, _ in statuses), statuses
            listed = subprocess.run([str(binary), 'machine', 'list', '--json'], env=env, cwd=root, capture_output=True, check=True, timeout=15)
            return {machine['label'] for machine in json.loads(listed.stdout)['machines']}
        for round in range(3):
            labels = {f'r{round}m{index}' for index in range(16)}
            assert race([['add', label, address(label + '.host')] for label in labels]) == labels
            assert race([['remove', label] for label in labels]) == set()


def receive_config_bounds(binary):
    """The receiving end of a sync applies what a whole stream carries: a stream cut before
    its end fails, one past the size or file caps is refused, and a changed file of the same
    size and mode is rewritten."""
    with tempfile.TemporaryDirectory(prefix='telar-machines-', dir='/tmp') as temporary:
        root = Path(temporary).resolve()
        env = environment(root)

        def receive(data):
            return subprocess.run([str(binary), 'machine', 'receive-config'], input=data, env=env, cwd=root, capture_output=True, timeout=60)

        cut = receive(b'telar-config 1\nfile 644 1 .claude/a\nx\n')
        assert cut.returncode == 1 and b'InvalidConfigStream' in cut.stderr and b'written' not in cut.stdout, cut
        megabyte = 1024 * 1024
        files = b''.join(f'file 644 {megabyte} .claude/big{index}\n'.encode() + b'x' * megabyte + b'\n' for index in range(16))
        large = receive(b'telar-config 1\n' + files + b'file 644 1 .claude/over\nx\nend\n')
        assert large.returncode == 1 and b'ConfigStreamTooLarge' in large.stderr, (large.returncode, large.stderr)
        many = receive(b'telar-config 1\n' + b''.join(f'file 644 0 .claude/many/{index}\n\n'.encode() for index in range(4097)) + b'end\n')
        assert many.returncode == 1 and b'ConfigStreamTooLarge' in many.stderr, (many.returncode, many.stderr)
        target = root / 'home/.claude/same'
        target.parent.mkdir(exist_ok=True)
        target.write_bytes(b'xy')
        target.chmod(0o644)
        changed = receive(b'telar-config 1\nfile 644 2 .claude/same\nyz\nend\n')
        assert changed.returncode == 0 and b'written .claude/same' in changed.stdout and target.read_bytes() == b'yz', changed


def dispatch_refusals(binary):
    """What dispatch refuses reaches neither the gateway nor a window: a command too long for the
    remote shell, and a window asked to show a second machine."""
    with tempfile.TemporaryDirectory(prefix='telar-machines-', dir='/tmp') as temporary:
        root = Path(temporary).resolve()
        env = environment(root)
        bindir = root / 'bin'
        bindir.mkdir()
        calls = root / 'calls'
        # A copy of telar beside its runtime and a window that records being opened.
        shutil.copy2(binary, bindir / 'telar')
        (bindir / 'telar-runtime').symlink_to(binary.resolve().parent / 'telar-runtime')
        install_gateway(bindir, env, f'#!/bin/sh\necho gateway "$@" >> "{calls}"\nexit 0\n')
        (bindir / 'telar-gui').write_text(f'#!/bin/sh\necho telar-gui "$@" >> "{calls}"\nexit 0\n')
        (bindir / 'telar-gui').chmod(0o700)
        env['PATH'] = f'{bindir}:/usr/bin:/bin'
        telar = bindir / 'telar'
        subprocess.run([str(telar), 'machine', 'add', 'box', address('host')], env=env, cwd=root, check=True, capture_output=True, timeout=15)
        try:
            for words in (['pane', 'list', '--workspace', 'w' * 70 * 1024], ['--remote', address('other')], ['gui', '--machine', 'other']):
                result = subprocess.run([str(telar), '--machine', 'box', *words], env=env, cwd=root, stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
                assert result.returncode == 1 and not calls.exists(), (words[0], result.returncode, result.stderr[-300:], calls.exists() and calls.read_text()[:300])
        finally:
            subprocess.run([str(telar), 'server', 'stop'], env=env, cwd=root, capture_output=True, timeout=15)


def contracts(binary):
    """Machine contracts asserted on their effects alone, beside the recorded outputs."""
    incompatible_runtime_kept(binary)
    concurrent_edits(binary)
    receive_config_bounds(binary)
    dispatch_refusals(binary)
    return 5
