#!/usr/bin/env python3
"""Check machine files, argv dispatch, CLI links and startup validation in private homes."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import socket
import tempfile


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
        value = value.replace('886b480d', '@SCHEMA@').replace('cqp00002', '@SCHEMA@')
        return value
    return value


def snapshot(root, binary):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            result[str(path.relative_to(root))] = {'link': normalize(os.readlink(path), root, binary)}
        elif path.is_file() and path.name != 'ssh':
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
        for args in [[], ['wat'], ['add'], ['add', 'box'], ['check'], ['receive-config', 'extra'], ['list', '--socket', '/x'],
                     ['add','box','host','--color'], ['add','box','host','--color','red','--color','blue'],
                     ['add','box','host','--binary','x'], ['add','box','host','--skip','agents'],
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
        for words in [[], ['gui'], ['/bin/echo','literal'], ['--machine','box'], ['--remote','user@host']]:
            run('no-display-'+repr(words), words)
        del env['SSH_CONNECTION']
        run('empty-list', ['machine','list'])
        run('empty-list-json', ['machine','list','--json'])
        for label,destination,color in [('bad label','host',None), ('box','-option',None), ('box','bad host',None), ('box','host','not a color')]:
            run('invalid-fields-' + label + destination, ['machine','add',label,destination] + (['--color',color] if color else []))
        run('add', ['machine','add','box','dev@host','--color','#aBc123'])
        run('duplicate-label', ['machine','add','box','other'])
        run('duplicate-destination', ['machine','add','gpu','dev@host'])
        run('second-machine', ['machine','add','gpu','other','--disabled'])
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
        fixture = {'version':2,'local_label':'local','machines':[{'id':'m-0123456789ab','label':'box','destination':'host',
                   'telar_path':'/opt/telar','enabled':False,'logins':{'claude':'done','codex':'pending','pi':'failed'}}]}
        profiles.write_text(json.dumps(fixture))
        run('extended-list', ['machine','list'])
        run('extended-list-json', ['machine','list','--json'])
        run('local-collision', ['machine','add','local','other'])
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
        (bindir/'ssh').write_text('#!/bin/sh\nprintf "%s\\n" "$@"\nexit 37\n')
        (bindir/'ssh').chmod(0o755)
        env['PATH']=str(bindir)+':/usr/bin:/bin'
        # The isolated profile is disabled: dispatch still explicitly selects it.
        run('ssh-forward', ['--machine','box','cli','status','--dir',"space ' quote $(touch nope);\nline"])
        schema = 'cqp00002' if b'cqp00002' in binary.read_bytes() else '886b480d'
        fixtures = [
            ('reachable', f'printf "%s\\n" "$HOME" /bin/sh "{root}/remote.sock" {schema}\n'),
            ('incompatible', f'printf "%s\\n" "$HOME" /bin/sh "{root}/remote.sock" deadbeef\n'),
            ('unreadable', 'printf "startup banner\\n"\n'),
            ('missing', 'echo "sh: telar: command not found" >&2\nexit 127\n'),
            ('host-key', 'echo "No ED25519 host key is known and you have requested strict checking." >&2\necho "Host key verification failed." >&2\nexit 255\n'),
            ('auth', 'echo "user@host: Permission denied (publickey)." >&2\nexit 255\n'),
            ('runtime-mismatch', 'echo "telar protocol mismatch" >&2\nexit 1\n')]
        for label, body in fixtures:
            (bindir/'ssh').write_text('#!/bin/sh\n' + body)
            run('check-' + label, ['machine','check','box'])
            run('check-json-' + label, ['machine','check','box','--json'])
        run('check-unknown', ['machine','check','missing','--json'])
        (bindir/'ssh').write_text('#!/bin/sh\necho "user@host: Permission denied (publickey)." >&2\nexit 255\n')
        run('setup-ssh-failure', ['machine','setup','box','--json'])
        run('add-check-failure', ['machine','add','new','newhost','--check','--json'])
        for args in [['setup','host','--confirm','--json'], ['setup','ssh://dev@new:22','--label','fresh','--confirm'],
                     ['setup','host','--binary',str(root/'missing')]]:
            run('setup-'+repr(args), ['machine',*args])
        # A deterministic SSH endpoint exercises setup effects without downloads
        # or writes on a real remote account. Only the transport is substituted.
        shim = "#!/usr/bin/env python3\nimport os,sys,shlex\ncommand=sys.argv[-1]\n"
        shim += "schema=" + repr(schema) + "\n"
        shim += "if command.endswith(\"server endpoint'\"):\n print(os.environ['HOME']);print('/bin/sh');print(os.environ['HOME']+'/remote.sock');print(schema)\n"
        shim += "else:\n script=sys.stdin.read()\n if script.startswith('dir='):\n  directory=shlex.split(script.splitlines()[0].split('=',1)[1])[0]\n  print('os=Darwin\\narch=arm64\\nlibc=gnu\\nhome='+os.environ['HOME'])\n  print('target='+os.environ['HOME']+'/.local/share/telar/versions/'+directory+'/telar')\n  print('installed=telar 0.0.0')\n elif 'link=$HOME/.local/bin/telar' in script:print('linked')\n"
        (bindir/'ssh').write_text(shim)
        for words in [['setup','box','--json'], ['setup','box','--json'], ['setup','box','--skip','agents,config,login','--json'],
                      ['setup','new-destination','--label','new-machine','--json']]:
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
