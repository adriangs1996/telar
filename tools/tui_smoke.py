import os,json,time,subprocess,tempfile,pty,threading,select,fcntl,termios,struct,signal,shutil
from pathlib import Path
validation=Path(__file__).resolve().parent
binary=validation.parent/'zig-out/bin/telar'
with tempfile.TemporaryDirectory(prefix='telar-client-smoke-',dir='/tmp') as temp:
 root=Path(temp);endpoint=root/'runtime.sock';cfg=root/'config.lua'
 shutil.copytree(binary.parents[2]/'examples/plugins/sample',root/'plugin')
 cfg.write_text('local t = require("telar")\nreturn t.config({api_version=2, plugins={t.plugin({path="plugin", enabled=false})}})\n')
 env=dict(os.environ,XDG_DATA_HOME=str(root/'data'),XDG_CONFIG_HOME=str(root/'config'),SHELL='/bin/sh',TERM='xterm-256color',TELAR_SOCKET=str(endpoint))
 server_output=(root/'server.log').open('w+')
 server=subprocess.Popen([str(binary),'server','--no-config','--socket',str(endpoint)],stdout=server_output,stderr=server_output,env=env,cwd=root)
 client_pid=None;master=None;stop=threading.Event();captured=bytearray()
 def run(*args, quiet=False):
  result=subprocess.run([str(binary),*map(str,args),'--socket',str(endpoint),'--json'],cwd=root,env=env,capture_output=True,text=True,timeout=12)
  if quiet and result.returncode!=0:
   print('WAIT '+result.stderr.strip(),flush=True);return []
  assert result.returncode==0,(args,result.returncode,result.stderr,result.stdout)
  if not quiet:print('PASS '+' '.join(map(str,args)),flush=True)
  return json.loads(result.stdout)
 def drain():
  while not stop.is_set():
   try:
    if select.select([master],[],[],.1)[0]:
     data=os.read(master,65536)
     if not data:break
     if len(captured)<200000:captured.extend(data)
   except OSError:break
 try:
  deadline=time.monotonic()+8
  while not endpoint.exists() and server.poll() is None and time.monotonic()<deadline:time.sleep(.05)
  assert endpoint.exists(),'server startup'
  time.sleep(.2)
  run('runtime','status')
  client_pid,master=pty.fork()
  if client_pid==0:
   os.chdir(root);os.execve(str(binary),[str(binary),'--config',str(cfg),'--sidebar-renderer','cells','--','/bin/sh'],env)
  fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',40,140,0,0))
  thread=threading.Thread(target=drain,daemon=True);thread.start()
  time.sleep(.5)
  deadline=time.monotonic()+12
  while True:
   clients=run('client','list',quiet=True)
   if clients:break
   if time.monotonic()>deadline:raise AssertionError('UI did not register: '+repr(bytes(captured[-4000:])))
   time.sleep(.1)
  cid=clients[0]['id']
  def ui(*args):return run(*args,'--client',cid)
  ui('sidebar','get');ui('sidebar','hide');assert not ui('sidebar','get')['visible'];ui('sidebar','show');assert ui('sidebar','get')['visible']
  ui('sidebar','resize','24')
  ui('workspace-list','collapse');ui('workspace-list','expand')
  before=ui('config','show')['generation'];ui('config','reload')
  deadline=time.monotonic()+8
  while ui('config','show')['generation']==before:
   assert time.monotonic()<deadline,'reload was not adopted';time.sleep(.3)
  assert not ui('plugin','list')[0]['enabled']
  ui('plugin','get','plugin');ui('plugin','enable','plugin')
  deadline=time.monotonic()+8
  while not ui('plugin','list')[0]['enabled']:
   assert time.monotonic()<deadline,'enable was not adopted';time.sleep(.3)
  plugin=ui('plugin','get','dev.telar.sample');assert plugin['actions']==['toggle'],plugin
  visible=ui('sidebar','get')['visible'];ui('plugin','run','dev.telar.sample','toggle')
  deadline=time.monotonic()+8
  while ui('sidebar','get')['visible']==visible:
   assert time.monotonic()<deadline,'worker action was not applied';time.sleep(.3)
  ui('plugin','disable','dev.telar.sample')
  deadline=time.monotonic()+8
  while ui('plugin','list')[0]['enabled']:
   assert time.monotonic()<deadline,'disable was not adopted';time.sleep(.3)
  panes=run('pane','list');assert panes,panes;pid=panes[0]['pane_id']
  ui('pane','focus',pid);ui('pane','fullscreen',pid);ui('pane','fullscreen',pid)
  layout=ui('layout','get');ui('layout','apply',layout['data'])
  for axis in ('horizontal','vertical'):
   ui('pane','split',pid,axis);time.sleep(.3)
   split=run('pane','list');assert len(split)==2,split
   ui('pane','close',split[-1]['pane_id']);time.sleep(.3)
   assert len(run('pane','list'))==1
  run('client','detach',cid)
  print('Real client command smoke passed',flush=True)
 finally:
  if client_pid:
   try:os.kill(client_pid,signal.SIGTERM)
   except ProcessLookupError:pass
   try:os.waitpid(client_pid,0)
   except ChildProcessError:pass
  stop.set()
  if master is not None:os.close(master)
  (validation/'tui-terminal.log').write_bytes(captured)
  if server.poll() is None:
   try:subprocess.run([str(binary),'server','stop','--socket',str(endpoint)],env=env,capture_output=True,timeout=5);server.wait(timeout=5)
   except Exception:server.terminate();server.wait(timeout=5)
  server_output.seek(0);(validation/'tui-server.log').write_text(server_output.read());server_output.close()
