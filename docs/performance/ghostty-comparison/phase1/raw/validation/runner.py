from pathlib import Path
import hashlib
import json
import shutil
import subprocess

root=Path('/Users/adriangonzalez/sandbox/telar')
work=Path('/tmp/tgb-diagnostic-source')
baseline=Path('/tmp/tgb-source')
out=Path('/tmp/tgb-phase1-validation')
out.mkdir(exist_ok=True)
paths=['src/backend/runtime/attachment/AttachmentStore.zig','src/backend/pty/Session.zig','src/backend/pty/native.zig','src/backend/pty/session_support.zig','src/backend/pane/blit.zig']
for path in paths:
    shutil.copy2(root/path,work/path)
source=work/'build.zig'
text=source.read_text().replace('.filters = &.{"agent panes survive consecutive"}', '.filters = &.{"agent panes survive consecutive", "default colours refresh"}')
source.write_text(text)
records=[]
def run(name,args):
    with (out/f'{name}.log').open('w') as log:
        result=subprocess.run(['zig','build',*args,'--summary','all'],cwd=work,stdout=log,stderr=subprocess.STDOUT)
    records.append(dict(name=name,args=args,returncode=result.returncode))
    (out/'results.json').write_text(json.dumps(records,indent=2))
    print(json.dumps(records[-1]),flush=True)

run('final-tests',['test-optimization','-Doptimize=ReleaseFast'])
try:
    for path in paths:
        shutil.copy2(baseline/path,work/path)
    shutil.copy2('/tmp/tgb-blit-before-with-test.zig',work/'src/backend/pane/blit.zig')
    run('baseline-control',['test-checkpoint-diagnostic','-Doptimize=ReleaseFast'])
    shutil.copy2(baseline/'src/backend/pane/blit.zig',work/'src/backend/pane/blit.zig')
    run('baseline-diagnostic-build',['-Doptimize=ReleaseFast','-Ddiagnostics=true','--prefix','/tmp/tgb-phase1-baseline-diagnostic'])
finally:
    for path in paths:
        shutil.copy2(root/path,work/path)
run('final-rebuild',['-Doptimize=ReleaseFast','--prefix','/tmp/tgb-phase1-final-verified'])
run('final-diagnostic-rebuild',['-Doptimize=ReleaseFast','-Ddiagnostics=true','--prefix','/tmp/tgb-phase1-final-diagnostic'])
