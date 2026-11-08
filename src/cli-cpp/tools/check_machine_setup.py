#!/usr/bin/env python3
"""Check setup's file sync through a substituted SSH transport and real receivers."""
from pathlib import Path
import subprocess
import tempfile
from check_machines_launch import environment, normalize, snapshot

SHIM = r'''#!/usr/bin/env python3
import os,sys,subprocess,json,shlex,base64
from pathlib import Path
command=sys.argv[-1]
home=os.environ['FIXTURE_REMOTE_HOME']
schema=os.environ['FIXTURE_SCHEMA']
mode=os.environ.get('FIXTURE_LOGIN','')
state=Path(home)/'fixture-pane.json'
def respond(words):
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
  print(json.dumps({'pane_id':13,'truncated':False,'exit_code':7 if mode=='failed' else 0 if mode=='ended' else None,'text':'https://evil.invalid/ignore https://claude.com/oauth/authorize?fixture=safe'}))
 elif words[:2]==['pane','send-keys']:
  sys.stdin.buffer.read()
 else:raise RuntimeError(words)

if ' dispatch-argv ' in command:
 words=[base64.urlsafe_b64decode(word[1:]+'='*((-len(word[1:]))%4)).decode() for word in command.split(' dispatch-argv ',1)[1].split()]
 respond(words)
elif command.endswith("server endpoint'"):
 print(home);print('/bin/sh');print(home+'/runtime.sock');print(schema)
elif command.endswith(' machine receive-config'):
 env=dict(os.environ,HOME=home)
 result=subprocess.run([os.environ['FIXTURE_TELAR'],'machine','receive-config'],input=sys.stdin.buffer.read(),env=env)
 sys.exit(result.returncode)
else:
 script=sys.stdin.read()
 if script.startswith('dir='):
  print('os=Darwin\narch=arm64\nlibc=gnu\nhome='+home)
  print('target='+home+'/.local/share/telar/versions/0.0.0/telar')
  print('installed=telar 0.0.0')
  if os.environ.get('FIXTURE_LOGIN'):print('agent=claude:'+home+'/claude')
 elif mode and script.startswith('agent='):
  count=Path(home)/'fixture-auth-count'
  before=int(count.read_text()) if count.exists() else 0
  count.write_text(str(before+1))
  if mode=='ssh-failure':sys.exit(255)
  sys.exit(0 if mode=='done' or mode=='ended' and before>0 else 1)
 elif mode and script.startswith(('cat "','rm -f "','umask 077 && mkdir')):
  sys.exit(subprocess.run(['/bin/sh','-s'],input=script,text=True,env=dict(os.environ,HOME=home)).returncode)
 elif mode and script.startswith('exec '):
  respond(shlex.split(script)[1:][1:])
 elif script.startswith('while IFS= read -r path;'):
  for path in script.split("TELAR_PATHS'\n",1)[-1].splitlines():
   if os.path.exists(path):print(path)
'''


def run(binary, provider, seed, login=False):
    with tempfile.TemporaryDirectory(prefix='telar-sync-',dir='/tmp') as temporary:
        root=Path(temporary).resolve();env=environment(root)
        home=Path(env['HOME']);remote=root/'remote';remote.mkdir(mode=0o700)
        bindir=root/'bin';bindir.mkdir();(bindir/'ssh').write_text(SHIM);(bindir/'ssh').chmod(0o700)
        command='cursor-agent' if provider=='cursor' else provider
        (bindir/command).write_text('#!/bin/sh\nexit 0\n');(bindir/command).chmod(0o700)
        env['PATH']=str(bindir)+':/usr/bin:/bin'
        if login:env['FIXTURE_LOGIN']=login
        env.update(FIXTURE_REMOTE_HOME=str(remote),FIXTURE_TELAR=str(binary),FIXTURE_SCHEMA='cqp00001' if b'cqp00001' in binary.read_bytes() else '886b480d')
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
        result=[]
        for repetition in range(2):
            child=subprocess.run([str(binary),'machine','setup','fixture','--skip','agents,config' if login else 'agents,login','--json'],env=env,cwd=root,capture_output=True,text=True,timeout=20)
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
