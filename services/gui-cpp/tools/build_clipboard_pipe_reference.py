import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description='Build unchanged original Linux ClipboardSource with a thin POSIX pipe adapter')
parser.add_argument('--output', type=Path, required=True)
options = parser.parse_args()
repository = Path(__file__).resolve().parents[3]
output = options.output.resolve()
output.mkdir(parents=True, exist_ok=False)
sources = {}
for name in ('lib/window/linux/ClipboardSource.zig', 'lib/window/ClipboardLimits.zig', 'services/gui-cpp/tools/reference_clipboard_pipe/probe.zig'):
    source = repository / name
    relative = name.removeprefix('lib/') if name.startswith('lib/') else 'probe.zig'
    target = output / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    sources[name] = hashlib.sha256(source.read_bytes()).hexdigest()
(output / 'window/native.zig').write_text('pub const c = @cImport({ @cInclude("poll.h"); @cInclude("unistd.h"); @cInclude("errno.h"); @cInclude("time.h"); @cInclude("stdlib.h"); });\n')
binary = output / 'clipboard-pipe-reference'
command = ['zig', 'build-exe', '-O', 'ReleaseFast', '-lc', str(output / 'probe.zig'), '-femit-bin=' + str(binary)]
receipt = dict(scope='Unchanged original ClipboardSource and limits; POSIX import and stdin/stdout adapter only', source_sha256=sources, command=command)
with (output / 'build.log').open('w') as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
receipt['exit_code'] = result.returncode
if result.returncode == 0:
    receipt['binary_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
(output / 'build.json').write_text(json.dumps(receipt, indent=2) + '\n')
result.check_returncode()
print('Original-source pipe reference built')
