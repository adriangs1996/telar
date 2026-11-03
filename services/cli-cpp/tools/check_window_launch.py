#!/usr/bin/env python3
"""Run window startup against a private C++ runtime and a GUI argv fixture or Qt GUI."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
from check_machines_launch import environment


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telar',type=Path,required=True)
    parser.add_argument('--runtime',type=Path,required=True)
    parser.add_argument('--gui',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    report={'checks':[],'passed':False}
    with tempfile.TemporaryDirectory(prefix='telar-window-',dir='/tmp') as temporary:
        root=Path(temporary).resolve();env=environment(root)
        bundle=root/'Telar.app/Contents';bindir=bundle/'Resources/bin';bindir.mkdir(parents=True)
        shutil.copy2(args.telar,bindir/'telar');shutil.copy2(args.telar.resolve().parent/'telar-launch.so',bindir/'telar-launch.so');(bindir/'telar-runtime').symlink_to(args.runtime.resolve())
        macos=bundle/'MacOS';macos.mkdir();gui=macos/'telar-gui'
        gui.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n');gui.chmod(0o755)
        telar=bindir/'telar';socket=root/'runtime.sock'
        def run(words):
            return subprocess.run([str(telar),*words],env=env,cwd=root,capture_output=True,text=True,timeout=30)
        try:
            result=run(['--fresh','--no-config','--theme=OSAKA_JADE','/bin/echo',"space ' quote",'--help'])
            assert result.returncode==0,(result.stdout,result.stderr)
            command=json.loads(result.stdout)
            expected=['--socket',str(socket),'--cwd',str(root),'--theme','shade','--no-config','--fresh','--','/bin/echo',"space ' quote",'--help']
            assert command==expected,(command,expected)
            report['checks'].append('bundle GUI resolution, runtime startup, theme alias, literal child argv')
            result=run(['--fresh','--no-config'])
            assert result.returncode==1 and result.stderr=='telar: a runtime is already running; stop it first (telar server stop) or drop --fresh\nerror: RuntimeAlreadyRunning\n',result
            report['checks'].append('fresh refuses a running runtime')
            for words in [[],['gui','--login-shell','--no-config','/bin/echo','--login-shell','literal'],['--remote','user@host','--no-config','/bin/echo','ok'],['--machine','local','--no-config'],['gui','--config',str(root/'config.lua'),'--profile','work','--theme','vesper','/bin/echo','--x']]:
                profiles=Path(env['XDG_CONFIG_HOME'])/'telar/machines.json';profiles.parent.mkdir(exist_ok=True);profiles.write_text('{"version":1,"local_label":"local","machines":[]}');profiles.chmod(0o600)
                result=run(words)
                assert result.returncode==0,(words,result.stdout,result.stderr)
                command=json.loads(result.stdout)
                assert command[:4]==['--socket',str(socket),'--cwd',str(root)],command
                if '--remote' in words:assert command[4:6]==['--remote','user@host'],command
                if '--machine' in words:assert command[4:6]==['--machine','local'],command
                if '--login-shell' in words:assert command[-3:]==['/bin/echo','literal'][-3:] or command[-2:]==['/bin/echo','literal'],command
            report['checks'].append('no-arg, gui login-shell, remote, saved machine and config/profile forwarding')
            # A sibling executable takes precedence over the bundle fallback.
            sibling=bindir/'telar-gui';sibling.write_text('#!/bin/sh\necho sibling\n');sibling.chmod(0o700)
            result=run(['--no-config']);assert result.stdout=='sibling\n',result
            sibling.unlink();report['checks'].append('sibling GUI takes precedence over bundle GUI')
            if args.gui:
                # The schema handshake is checked by the real GUI, not inferred from its path.
                gui.write_text('#!/bin/sh\nexec '+shlex.quote(str(args.gui.resolve()))+' --smoke-ms 1600 "$@"\n')
                marker=root/'child-ran'
                result=run(['--no-config','/bin/sh','-c','printf launched > '+shlex.quote(str(marker))+'; sleep 5'])
                assert result.returncode==0 and 'connected=1' in result.stdout and marker.read_text()=='launched',(result.stdout,result.stderr)
                report['gui_stdout']=result.stdout
                report['checks'].append('real Qt window attaches and runs literal child command')
            report['passed']=True
        except Exception as error:
            report['failure']=str(error);raise
        finally:
            subprocess.run([str(telar),'server','stop','--socket',str(socket)],env=env,capture_output=True,timeout=10)
            args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))


if __name__=='__main__':main()
