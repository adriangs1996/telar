#!/usr/bin/env python3
"""Compare real GUI launch effects and runtime survival, stack against stack."""
import argparse
import json
from pathlib import Path
import os
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
from check_machines_launch import environment, normalize


def run(binary, gui, runtime, scenario):
    with tempfile.TemporaryDirectory(prefix='telar-window-parity-',dir='/tmp') as temporary:
        root=Path(temporary).resolve();env=environment(root)
        bindir=root/'bin';bindir.mkdir()
        telar=binary
        if runtime:
            shutil.copy2(binary,bindir/'telar');telar=bindir/'telar'
            (bindir/'telar-runtime').symlink_to(runtime)
            (bindir/'telar-gui').symlink_to(gui)
        marker=root/'child';pidfile=root/'child.pid'
        child='printf launched > '+shlex.quote(str(marker))+'; printf "%s" $$ > '+shlex.quote(str(pidfile))+'; exec /bin/sleep 60'
        shell=root/'shell';shell.write_text('#!/bin/sh\n'+child+'\n');shell.chmod(0o700)
        env['SHELL']=str(shell)
        command=[] if scenario=='no-args' else ['--no-config','--theme','OSAKA_JADE','--fresh','/bin/sh','-c',child]
        if scenario=='gui':command=['gui',*command]
        if scenario=='profile':
            config=root/'config.lua';config.write_text("return {api_version=2,profiles={work={theme='vesper'}}}\n")
            command=['--config',str(config),'--profile','work',*command[1:]]
        started=subprocess.Popen([str(telar),*command],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        endpoint=root/'runtime.sock'
        try:
            deadline=time.monotonic()+25
            while not marker.exists():
                if started.poll() is not None:
                    out,err=started.communicate();raise RuntimeError((started.returncode,out,err))
                if time.monotonic()>deadline:raise TimeoutError('GUI did not launch the child command')
                time.sleep(.05)
            started.terminate();out,err=started.communicate(timeout=10)
            child_pid=int(pidfile.read_text());os.kill(child_pid,0)
            result=subprocess.run([str(telar),'server','endpoint','--socket',str(endpoint)],env=env,capture_output=True,text=True,timeout=15)
            assert result.returncode==0,result
            # Wire schema IDs intentionally differ across the two stacks.
            lines=result.stdout.splitlines();assert lines[0]==str(endpoint) and len(lines)==2,result
            return {'exit':started.returncode,'stdout':normalize(out.decode(errors='replace'),root,telar),
                    'stderr':normalize(err.decode(errors='replace'),root,telar),'child':marker.read_text(),
                    'runtime_survives':True,'child_survives':True}
        finally:
            if started.poll() is None:started.kill();started.communicate()
            subprocess.run([str(telar),'server','stop','--socket',str(endpoint)],env=env,capture_output=True,timeout=15)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ('zig','cpp','runtime','gui','output'):parser.add_argument('--'+key,type=Path,required=True)
    args=parser.parse_args();cases=[]
    for scenario in ('no-args','command','gui','profile'):
        zig=run(args.zig.resolve(),None,None,scenario)
        cpp=run(args.cpp.resolve(),args.gui.resolve(),args.runtime.resolve(),scenario)
        differences=[key for key in zig if zig[key]!=cpp[key]]
        cases.append({'name':scenario,'zig':zig,'cpp':cpp,'equal':not differences,'differences':differences})
        print(scenario,differences,flush=True)
    report={'passed':all(case['equal'] for case in cases),'cases':cases,
            'normalization':'Private paths and executable paths; endpoint wire schemas differ by design. Both windows receive SIGTERM after the child writes its marker.'}
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    return 0 if report['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
