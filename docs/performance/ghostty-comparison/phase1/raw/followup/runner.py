import json
from pathlib import Path
import subprocess
import sys

root=Path('/Users/adriangonzalez/sandbox/telar')
out=Path('/tmp/tgb-phase1-followup')
out.mkdir()
commands=[]
for name,binary in [('baseline','/tmp/tgb-phase1-baseline-diagnostic/bin/telar'),('candidate','/tmp/tgb-phase1-final-diagnostic/bin/telar')]:
    commands.append((f'diagnostic-{name}', [sys.executable,str(root/'tools/terminal_runtime_bench.py'),'--binary',binary,'--output',str(out/f'diagnostic-{name}'),'--settle-seconds','3']))
for round_index in range(3):
    commands.append((f'sustained-{round_index}', [sys.executable,str(root/'tools/terminal_runtime_bench.py'),'--binary','/tmp/tgb-phase1-final-verified/bin/telar','--output',str(out/f'sustained-{round_index}'),'--mib','64']))
commands.append(('profile', [sys.executable,str(root/'tools/terminal_runtime_bench.py'),'--binary','/tmp/tgb-phase1-final-verified/bin/telar','--output',str(out/'profile'),'--mib','512','--sample']))
records=[]
for name, command in commands:
    with (out/f'{name}.log').open('w') as log:
        result=subprocess.run(command,cwd=root,stdout=log,stderr=subprocess.STDOUT)
    records.append(dict(name=name,command=command,returncode=result.returncode))
    (out/'runs.json').write_text(json.dumps(records,indent=2))
    print(json.dumps(records[-1]),flush=True)
    if result.returncode:
        sys.exit(result.returncode)
