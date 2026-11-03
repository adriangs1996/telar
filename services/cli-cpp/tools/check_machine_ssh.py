#!/usr/bin/env python3
"""Exercise --machine over a private localhost sshd, without account configuration changes."""
import argparse
import json
import os
from pathlib import Path
import pwd
import shutil
import socket
import subprocess
import tempfile
import time
from check_machines_launch import environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telar', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runtime', type=Path)
    parser.add_argument('--gui', type=Path)
    args = parser.parse_args()
    binary = args.telar.resolve()
    report = {'binary': str(binary), 'checks': [], 'passed': False}
    with tempfile.TemporaryDirectory(prefix='telar-ssh-', dir='/tmp') as temporary:
        root = Path(temporary).resolve()
        env = environment(root)
        remote = root/'remote';remote.mkdir(mode=0o700)
        remote_env = environment(remote)
        for name in ('host-key', 'client-key'):
            subprocess.run(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(root/name)],check=True,env=env)
        auth = root/'authorized_keys';auth.write_bytes((root/'client-key.pub').read_bytes());auth.chmod(0o600)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0));port=listener.getsockname()[1]
        forced=root/'forced'
        assignments=['HOME='+remote_env['HOME'],'PATH=/usr/bin:/bin','SHELL=/bin/sh']+[key+'='+remote_env[key] for key in ('TMPDIR','XDG_RUNTIME_DIR','XDG_DATA_HOME','XDG_CONFIG_HOME','XDG_STATE_HOME')]
        import shlex
        forced.write_text('#!/bin/sh\nexec /usr/bin/env -i '+ ' '.join(map(shlex.quote,assignments))+ ' /bin/sh -c "$SSH_ORIGINAL_COMMAND"\n')
        forced.chmod(0o700)
        config=root/'sshd_config'
        config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {root/'host-key'}
PidFile {root/'sshd.pid'}
AuthorizedKeysFile {auth}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
AllowUsers {pwd.getpwuid(os.getuid()).pw_name}
ForceCommand {forced}
LogLevel ERROR
''')
        sshconfig=root/'ssh_config'
        sshconfig.write_text(f'''Host fixture
  HostName 127.0.0.1
  Port {port}
  User {pwd.getpwuid(os.getuid()).pw_name}
  IdentityFile {root/'client-key'}
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile {root/'known_hosts'}
''')
        pub=(root/'host-key.pub').read_text().split()
        (root/'known_hosts').write_text(f'[127.0.0.1]:{port} {pub[0]} {pub[1]}\n')
        bindir=root/'bin';bindir.mkdir()
        (bindir/'ssh').write_text('#!/bin/sh\nexec /usr/bin/ssh -F '+shlex.quote(str(sshconfig))+' "$@"\n');(bindir/'ssh').chmod(0o700)
        env['PATH']=str(bindir)+':/usr/bin:/bin'
        profiles=Path(env['XDG_CONFIG_HOME'])/'telar/machines.json';profiles.parent.mkdir(mode=0o700)
        profiles.write_text(json.dumps({'version':2,'local_label':'here','machines':[{'id':'m-000000000001','label':'there','destination':'fixture','telar_path':str(binary),'enabled':False}]}));profiles.chmod(0o600)
        log=(root/'sshd.log').open('wb')
        server=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],env=env,stdout=log,stderr=log)
        try:
            deadline=time.monotonic()+5
            while True:
                if server.poll() is not None:raise RuntimeError((root/'sshd.log').read_text())
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=.2):break
                except OSError:
                    if time.monotonic()>deadline:raise
                    time.sleep(.05)
            def run(words,data=b''):
                return subprocess.run([str(binary),'--machine','there',*words],input=data,env=env,cwd=root,capture_output=True,timeout=40)
            result=run(['--version'])
            assert result.returncode==0 and result.stdout.startswith(b'telar '),result
            report['checks'].append('remote version through disabled isolated profile')
            result=run(['cli','status','--dir',str(remote/"space 'quote $(touch injected); line")])
            expected=f"telar cli: {remote}/space 'quote $(touch injected); line/telar is not installed\n".encode()
            assert result.returncode==0 and result.stdout==expected and not (remote/'injected').exists(),result
            report['checks'].append('literal quoted arguments survive real SSH')
            payload=b'telar-config 1\nfile 644 5 .claude/sample.txt\nhello\nend\n'
            result=run(['machine','receive-config'],payload)
            assert result.returncode==0 and (remote/'home/.claude/sample.txt').read_bytes()==b'hello',result
            report['checks'].append('stdin streams into remote receive-config')
            result=run(['cli','install','--dir',str(remote/'missing-parent')])
            assert result.returncode==1 and result.stderr==b'error: FileNotFound\n',result
            report['checks'].append('remote stderr and failure status propagate')
            if args.runtime:
                bundle = root/'upload';bundle.mkdir()
                shutil.copy2(binary,bundle/'telar');shutil.copy2(binary.parent/'telar-config-check',bundle/'telar-config-check');(bundle/'telar-runtime').symlink_to(args.runtime.resolve())
                for iteration in range(2):
                    setup=subprocess.run([str(binary),'machine','setup','there','--binary',str(bundle/'telar'),'--skip','agents,config,login','--json'],env=env,cwd=root,capture_output=True,text=True,timeout=90)
                    parsed=json.loads(setup.stdout)
                    assert setup.returncode==0 and parsed['ready'],(setup.stdout,setup.stderr)
                    report['setup_steps']=parsed['steps']
                installed_profiles=json.loads(profiles.read_text())
                target=Path(installed_profiles['machines'][0]['telar_path'])
                (target.parent/'telar-config-check').unlink()
                repaired=subprocess.run([str(binary),'machine','setup','there','--binary',str(bundle/'telar'),'--skip','agents,config,login','--json'],env=env,cwd=root,capture_output=True,text=True,timeout=90)
                assert repaired.returncode==0 and (target.parent/'telar-config-check').is_file(),(repaired.stdout,repaired.stderr)
                report['checks'].append('real SSH setup deploys all companions, is idempotent and repairs a missing companion')
                result=run(['--version'])
                assert result.returncode==0 and result.stdout.startswith(b'telar '),result
                report['checks'].append('dispatch uses setup-installed executable path')
                if args.gui:
                    gui=bundle/'telar-gui';gui.write_text('#!/bin/sh\nexec '+shlex.quote(str(args.gui.resolve()))+' --smoke-ms 2400 "$@"\n');gui.chmod(0o700)
                    marker=remote/'window-child'
                    opened=subprocess.run([str(bundle/'telar'),'--machine','there','--no-config','/bin/sh','-c','printf remote-window > '+shlex.quote(str(marker))+'; sleep 10'],env=env,cwd=root,capture_output=True,text=True,timeout=30)
                    assert opened.returncode==0 and marker.read_text()=='remote-window',(opened.stdout,opened.stderr)
                    report['checks'].append('real Qt window selects saved machine and launches command over SSH')

            report['passed']=True
        except Exception as error:
            report['failure']=str(error)
            raise
        finally:
            if (root/'upload/telar').exists():
                subprocess.run([str(root/'upload/telar'),'server','stop','--socket',str(root/'runtime.sock')],env=env,capture_output=True,timeout=10)
            installed=sorted((remote/'home/.local/share/telar/versions').glob('*/telar'))
            for program in installed:
                subprocess.run([str(program),'server','stop','--socket',str(Path(remote_env['XDG_RUNTIME_DIR'])/'telar/runtime.sock')],env=remote_env,capture_output=True,timeout=10)
            server.terminate()
            try:server.wait(timeout=5)
            except subprocess.TimeoutExpired:server.kill();server.wait()
            log.close()
            # End any private SSH control master owned by this fixture.
            for control in root.glob('ssh-*'):
                if control.is_socket():
                    subprocess.run(['/usr/bin/ssh','-F',str(sshconfig),'-S',str(control),'-O','exit','fixture'],env=env,capture_output=True,timeout=5)
            args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))


if __name__=='__main__':main()
