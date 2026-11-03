#!/usr/bin/env python3
"""Compare window CLI behavior, then optionally both complete runtime/GUI stacks."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from window_test import cases, environment, run_fixture


def invalid_cases():
    for family in ('client', 'sidebar', 'workspace-list', 'layout', 'notification', 'command', 'config'):
        yield [family]
        yield [family, 'unknown']
    for words in (['client','get'], ['client','get','0'], ['client','get','-1'], ['client','get','18446744073709551616'], ['client','list','--json','--json'], ['client','list','--socket'], ['sidebar','resize'], ['sidebar','resize','0'], ['sidebar','resize','65536'], ['layout','apply'], ['client','open'], ['client','open','unknown'], ['client','clipboard'], ['plugin','run'], ['plugin','run','test'], ['plugin','get'], ['notification','dismiss'], ['notification','show',''], ['notification','show','x','--level','bad'], ['notification','show','x','--duration','499'], ['notification','show','x','--duration','60001'], ['notification','show','x','--duration','4294967296'], ['notification','show','x','--pane','0'], ['notification','show','x','--body','a','--body','b'], ['notification','show','x','--pane','1','--tab','2'], ['command','suggest','0','x'], ['command','suggest','1',''], ['command','suggest','1','x'*513], ['config','check','a','b'], ['config','check','--profile'], ['config','check','--profile','a','--profile','b']):
        yield words
    for value in ('+7','-7','_7','7_','7a','18446744073709551616'):
        yield ['client','get',value]
    for command in (['sidebar','get'], ['workspace-list','expand'], ['layout','get'], ['client','copy-mode'], ['config','show'], ['plugin','list']):
        for tail in ([], ['--client'], ['--client','0'], ['--client','7','--json','--json'], ['--client','7','--client','8'], ['--client','7','--socket'], ['--client','7','--bad']):
            yield command + tail


def call(binary, words, env):
    result = subprocess.run([str(binary), *words], env=env, input=b'', capture_output=True, timeout=40)
    return dict(status=result.returncode, stdout=result.stdout.decode(errors='backslashreplace'), stderr=result.stderr.decode(errors='backslashreplace'))


def compare(report, name, zig, cpp):
    report['cases'].append(dict(name=name, equal=zig == cpp, zig=zig, cpp=cpp))


def configuration_sources(root):
    source = root / 'sources'
    source.mkdir(exist_ok=True)
    package=source/'example';package.mkdir(exist_ok=True)
    (package/'plugin.json').write_text(json.dumps(dict(api_version=1,id='sample',version='1',entry='main.lua',source=dict(url='fixture',revision='1'),actions=['run'],capabilities=[])))
    (package/'main.lua').write_text('return {actions={run=function() return nil end}}')
    (source/'valid.lua').write_text('return {api_version=2,plugins={{path="example"}}}\n')
    (source/'profile.lua').write_text('return {api_version=2,profiles={test={client={sidebar={visible=false}}}}}\n')
    (source/'syntax.lua').write_text('return {\n')
    (source/'version.lua').write_text('return {api_version=1}\n')
    (source/'unknown.lua').write_text('return {api_version=2,surprise=true}\n')
    (source/'duplicate.lua').write_text('local t=require("telar"); return {api_version=2,client={keybindings={t.bind({"x"},"detach"),t.bind({"x"},"history-palette")}}}\n')
    (source/'nested.lua').write_text('return {api_version=2,client={sidebar={visible="invalid"}}}')
    (source/'ambiguous.lua').write_text('return {api_version=2,client={keybindings={telar.bind({"x"},"detach"),telar.bind({"x","y"},"detach")}}}')
    (source/'module.lua').write_text('local x=require("settings"); return {api_version=2,client={sidebar={visible=x.visible}}}')
    (source/'settings.lua').write_text('return {visible=false}')
    (source/'call.lua').write_text('error("fixture")')
    (source/'retired.lua').write_text('return {api_version=2,client={icons={},sidebar={renderer=function() end},input={escape_timeout_ms=20},notifications={delivery="terminal"}}}')
    (source/'plugin-action.lua').write_text('return {api_version=2,client={keybindings={telar.bind({"x"},{kind="plugin",plugin="missing",action="run"})}}}')
    return source


def stack(binary, gui, root, source, cpp):
    env = environment(root)
    # Offscreen Qt owns an in-memory clipboard; it never reads/writes the desktop clipboard.
    if cpp:
        env['QT_QPA_PLATFORM'] = 'offscreen'
    sock = root / 'r.sock'
    env['TELAR_SOCKET_PATH'] = str(sock)
    runtime_log = (root/'runtime.log').open('w')
    runtime = subprocess.Popen([str(binary),'server','--socket',str(sock),'--no-config'], env=env, stdout=runtime_log, stderr=runtime_log)
    window = None
    results = {}
    def run(words):
        return call(binary,[*words,'--socket',str(sock)],env)
    try:
        deadline = time.monotonic()+15
        while not sock.exists():
            if runtime.poll() is not None or time.monotonic()>deadline:
                raise RuntimeError(f'Runtime startup failed: {root}')
            time.sleep(.05)
        for words in (['client','list'],['client','list','--json'],['client','get','999'],['sidebar','get','--client','999'],['notification','show','Fixture']):
            results['no-window/'+' '.join(words)] = run(words)
        window_log=(root/'gui.log').open('w')
        command = [str(gui),'--socket',str(sock),'--config',str(source/'valid.lua'),'--fresh','/bin/sh'] if cpp else [str(binary),'gui','--config',str(source/'valid.lua'),'/bin/sh']
        window = subprocess.Popen(command,env=env,stdout=window_log,stderr=window_log)
        deadline=time.monotonic()+25
        while True:
            listed=run(['client','list','--json'])
            entries=json.loads(listed['stdout']) if listed['status']==0 else []
            if entries and entries[0]["attachments"]>0: break
            if window.poll() is not None or time.monotonic()>deadline:
                raise RuntimeError(f'GUI startup failed: {root}')
            time.sleep(.1)
        client=entries[0]
        def normalized(result):
            output=result['stdout']
            if output.startswith('{'):
                value=json.loads(output)
                keys=[]
                if 'client_id' in value:keys+=['client_id','client_generation']
                if 'id' in value and 'detached' in value:keys+=['id','generation']
                if 'id' in value and 'identity' in value:keys+=['id','generation','identity']
                for key in keys:
                    output=re.sub(r'("'+key+r'":)\d+',r'\g<1>1',output,count=1)
                result=dict(result,stdout=output)
            return result
        cid=str(client['id'])
        results['window/notification-first']=run(['notification','show','Owned fixture','--duration','60000'])
        # Both fresh NotificationCenter implementations allocate first_id = 1.
        results['window/notification-dismiss-first']=normalized(run(['notification','dismiss','1','--client',cid,'--json']))
        results['window/notification-dismiss-again']=normalized(run(['notification','dismiss','1','--client',cid,'--json']))
        results['window/config-pretty']=run(['config','show','--client',cid])
        for enabled in (False,True):
            verb='enable' if enabled else 'disable'
            previous_generation=json.loads(run(['config','show','--client',cid,'--json'])['stdout'])['generation']
            results['window/plugin-'+verb]=normalized(run(['plugin',verb,'example','--client',cid,'--json']))
            deadline=time.monotonic()+10
            while True:
                listed=run(['plugin','list','--client',cid,'--json'])
                adopted_config=run(['config','show','--client',cid,'--json'])
                generation=json.loads(adopted_config['stdout'])['generation'] if adopted_config['status']==0 else 0
                if generation>previous_generation and listed['status']==0 and json.loads(listed['stdout'])[0]['enabled']==enabled:break
                if time.monotonic()>deadline:break
                time.sleep(.05)
            results['window/plugin-'+verb+'-adopted']=dict(listed,adopted=listed['status']==0 and json.loads(listed['stdout'])[0]['enabled']==enabled)
        commands=[['sidebar','get'],['sidebar','hide'],['sidebar','get'],['sidebar','show'],['sidebar','resize','35'],['workspace-list','collapse'],['workspace-list','expand'],['layout','get'],['layout','apply','invalid'],['config','show'],['config','show','--section','theme'],['config','show','--section','gui'],['config','show','--section','input'],['config','show','--section','runtime'],['config','show','--section','binding','--index','0'],['config','show','--section','bad'],['plugin','list'],['plugin','get','sample'],['plugin','run','sample','run'],['plugin','get','unknown'],['plugin','enable','unknown'],['plugin','disable','unknown'],['plugin','run','unknown','test'],['notification','dismiss','99999'],['client','open-link','invalid:fixture'],['config','reload'],['client','copy-mode'],['client','open','goto'],['client','open','history']]
        for index,words in enumerate(commands):
            results[f'window/{index}/'+ ' '.join(words)]=normalized(run([*words,'--client',cid,'--json']))
        exported=run(['layout','get','--client',cid,'--json'])
        if exported['status']==0:
            token=json.loads(exported['stdout'])['data']
            results['window/layout-apply-valid']=normalized(run(['layout','apply',token,'--client',cid,'--json']))
            # This fixture has one layout node: its final u64 is the discovered pane id.
            pane=str(int.from_bytes(bytes.fromhex(token)[-8:],'little'))
            results['window/suggest-unavailable']=run(['command','suggest',pane,'list files','--json'])
        results['window/client-get']=normalized(run(['client','get',cid,'--json']))
        results['window/notification-show']=run(['notification','show','Fixture'])
        results['window/notification-long']=run(['notification','show','é'*60])
        results['window/client-detach']=normalized(run(['client','detach',cid,'--json']))
        window.terminate();window.wait(timeout=10)
        window=subprocess.Popen(command,env=env,stdout=window_log,stderr=window_log)
        deadline=time.monotonic()+25
        while True:
            listed=run(['client','list','--json'])
            entries=json.loads(listed['stdout']) if listed['status']==0 else []
            if entries and entries[0]['attachments']>0:break
            if window.poll() is not None or time.monotonic()>deadline:raise RuntimeError('Second GUI did not attach')
            time.sleep(.1)
        cid=str(entries[0]['id'])
        results['window/fresh-history']=normalized(run(['client','open','history','--client',cid,'--json']))
        results['window/copy-with-history']=normalized(run(['client','copy-mode','--client',cid,'--json']))
    finally:
        if window is not None and window.poll() is None:
            window.terminate()
            try:window.wait(timeout=10)
            except subprocess.TimeoutExpired:window.kill();window.wait()
        if runtime.poll() is None:
            run(['server','stop'])
            try:runtime.wait(timeout=15)
            except subprocess.TimeoutExpired:runtime.terminate();runtime.wait(timeout=10)
    return results


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig',type=Path,required=True)
    parser.add_argument('--cpp',type=Path,required=True)
    parser.add_argument('--scratch',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--cpp-gui',type=Path)
    parser.add_argument('--timeouts',action='store_true')
    args=parser.parse_args()
    args.scratch.mkdir(parents=True,exist_ok=True)
    report={'scope':'CLI validation and wire fixtures; optional real runtime and GUI stacks', 'binaries':{k:dict(path=str(getattr(args,k)),sha256=hashlib.sha256(getattr(args,k).read_bytes()).hexdigest()) for k in ('zig','cpp')},'cases':[]}
    root=args.scratch
    env=environment(root)
    for index,words in enumerate(invalid_cases()):
        compare(report,f'validation/{index}/'+ ' '.join(words),call(args.zig,words,env),call(args.cpp,words,env))
    for index,(words,fixture,_,_) in enumerate(cases()):
        compare(report,f'wire/{index}/'+ ' '.join(words),run_fixture(args.zig,root,words,fixture),run_fixture(args.cpp,root,words,fixture))
    source=configuration_sources(root)
    for name in ('valid','profile','syntax','version','unknown','duplicate','missing','call','retired','plugin-action','nested','ambiguous','module'):
        words=['config','check',str(source/(name+'.lua'))]
        compare(report,'config/'+name,call(args.zig,words,env),call(args.cpp,words,env))
    if args.cpp_gui:
        results={}
        for kind in ('zig','cpp'):
            directory=root/kind;directory.mkdir(exist_ok=True)
            try:
                results[kind]=stack(getattr(args,kind),args.cpp_gui,directory,source,kind=='cpp')
            except Exception as error:
                report['stack_error']=str(error)
                args.output.write_text(json.dumps(report,indent=2)+'\n')
                raise
        for name in results['zig']:
            compare(report,name,results['zig'][name],results['cpp'][name])
    if args.timeouts:
        with ThreadPoolExecutor(max_workers=2) as executor:
            futures={}
            for kind in ('zig','cpp'):
                directory=root/('timeout-'+kind);directory.mkdir(exist_ok=True)
                futures[kind]=executor.submit(run_fixture,getattr(args,kind),directory,['client','list'],{'silent':True,'timeout':40})
            compare(report,'wire/receive-timeout',futures['zig'].result(),futures['cpp'].result())
    report['matched']=sum(case['equal'] for case in report['cases'])
    report['total']=len(report['cases'])
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(f"{report['matched']}/{report['total']} comparisons match; report: {args.output}")
    for case in report['cases']:
        if not case['equal']:print(case['name'])
    return report['matched']!=report['total']


if __name__=='__main__':
    sys.exit(main())
