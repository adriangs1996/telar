import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys

root = Path('/Users/adriangonzalez/sandbox/telar')
out = Path('/tmp/tgb-phase1-headless')
out.mkdir()
binaries = {
    'baseline': '/tmp/tgb-release/bin/telar',
    'credit': '/tmp/tgb-credit-borrow/bin/telar',
    'drain': '/tmp/tgb-drain-v1/bin/telar',
    'final': '/tmp/tgb-optimized-frozen/bin/telar',
}
(out / 'manifest.json').write_text(json.dumps({name: dict(path=path, sha256=hashlib.sha256(Path(path).read_bytes()).hexdigest()) for name, path in binaries.items()}, indent=2))
(out / 'processes-before.txt').write_text(subprocess.check_output(['ps', '-axo', 'pid,ppid,%cpu,rss,comm'], text=True))
results = []
for round_index in range(4):
    names = list(binaries)
    order = names[round_index:] + names[:round_index]
    for name in order:
        directory = out / f'{round_index}-{name}'
        subprocess.run([sys.executable, str(root / 'tools/terminal_runtime_bench.py'), '--binary', binaries[name], '--output', str(directory)], check=True)
        result = json.loads((directory / 'result.json').read_text())
        result.update(variant=name, round=round_index)
        result['shutdown'] = json.loads((directory / 'shutdown.json').read_text())
        results.append(result)
        (out / 'results.json').write_text(json.dumps(results, indent=2))
summary = {}
for name in binaries:
    summary[name] = {}
    for case in ['ascii', 'ansi']:
        rates = [c['mib_per_second'] for r in results if r['variant'] == name for c in r['cases'] if c['name'] == case]
        summary[name][case] = dict(median=statistics.median(rates), min=min(rates), max=max(rates), rates=rates)
(out / 'summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
