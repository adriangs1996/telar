import os,json,time,subprocess,tempfile
from pathlib import Path
validation=Path(__file__).resolve().parent
binary=validation.parent/'zig-out/bin/telar'
with tempfile.TemporaryDirectory(prefix='telar-smoke-',dir='/tmp') as temp:
 root=Path(temp); endpoint=root/'runtime.sock'
 env=dict(os.environ, XDG_DATA_HOME=str(root/'data'), XDG_CONFIG_HOME=str(root/'config'), SHELL='/bin/sh')
 with (root/'server.log').open('w+') as output:
  process=subprocess.Popen([str(binary),'server','--no-config','--socket',str(endpoint)],stdout=output,stderr=output,env=env,cwd=root)
  def run(*args,json_output=True):
   result=subprocess.run([str(binary),*map(str,args),'--socket',str(endpoint),*(['--json'] if json_output else [])],env=env,cwd=root,capture_output=True,text=True,timeout=12)
   assert result.returncode==0,(args,result.returncode,result.stderr,result.stdout)
   print('PASS '+' '.join(map(str,args)),flush=True)
   return json.loads(result.stdout) if json_output else result.stdout
  try:
   deadline=time.monotonic()+8
   while not endpoint.exists() and process.poll() is None and time.monotonic()<deadline: time.sleep(.05)
   assert endpoint.exists(),'runtime did not start'
   assert run('runtime','status')['running']
   run('runtime','metrics')
   run('proxy','watch','--count','1')
   assert run('workspace','list')==[]
   assert run('client','list')==[]
   assert run('pane','list')==[]
   created=run('workspace','create','--directory',root,'--name','CLI smoke')
   wid=created['workspace_id']
   run('workspace','get',wid)
   assert run('workspace','rename',wid,'Renamed smoke')['name']=='Renamed smoke'
   tabs=run('tab','list','--workspace',wid)
   assert len(tabs)==1,tabs
   tid=tabs[0]['tab_id']
   run('tab','get',tid,'--workspace',wid)
   run('tab','rename',tid,'smoke shell','--workspace',wid)
   panes=run('pane','list','--workspace',wid,'--tab',tid)
   assert len(panes)==1,panes
   pid=panes[0]['pane_id']
   run('pane','get',pid,'--workspace',wid,'--tab',tid)
   run('pane','send-keys',pid,"printf 'telar_cli_smoke_token\\n'",'--enter',json_output=False)
   deadline=time.monotonic()+5
   while True:
    text=run('pane','read',pid,json_output=False)
    if 'telar_cli_smoke_token' in text:break
    assert time.monotonic()<deadline,text
    time.sleep(.1)
   matches=run('pane','search',pid,'telar_cli_smoke_token')
   assert matches['matches'],matches
   run('pane','watch',pid,'--workspace',wid,'--tab',tid,'--count','1')
   logs=run('diagnostics','logs','--component','runtime','--lines','2')
   assert logs,logs
   run('tab','close',tid,'--workspace',wid)
   assert run('workspace','list')==[]
  finally:
   if process.poll() is None:
    try:run('server','stop',json_output=False);process.wait(timeout=5)
    except Exception:process.terminate();process.wait(timeout=5)
   output.seek(0)
   (validation/'runtime-server.log').write_text(output.read())
 print('Real runtime smoke passed',flush=True)
