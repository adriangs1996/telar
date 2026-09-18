import hashlib
import json
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, '/tmp/tgb-harness-closure')
from gui_tui_latency import measure, summarize, WARMUP

root = Path('/tmp/tgb-v2-layouts').resolve()
manifest = json.loads((root / 'manifest.json').read_text())
runs = json.loads((root / 'runs.json').read_text())
directory = root / '2-splits-load-ghostty'
result_path = directory / 'result.json'
result = json.loads(result_path.read_text())
assert result['failed'] == 0 and len(result['gpu_ms']) == 120
assert all(all(result[name]) and len(result[name]) == 120 for name in (
    'app_active_start', 'app_active_end', 'window_key_start', 'window_key_end'))
fixtures = [json.loads(p.read_text()) for p in sorted((directory / 'receipts').glob('*.json'))]
errors = [f for f in fixtures if f['error']]
assert len(fixtures) == 4 and len(errors) == 1
assert errors[0]['error'] == 'PTY write made no progress'
receipt = directory / 'receipts' / f'{errors[0]["pid"]}.json'
assert receipt.stat().st_mtime_ns > result_path.stat().st_mtime_ns
result.update(mode='ghostty', case='splits-load', round=2, warmup=WARMUP,
              pty_cells=json.loads((directory / 'size.json').read_text()),
              summary=summarize(result['gpu_ms'][WARMUP:]), fixtures=fixtures,
              post_measurement_cleanup_error=dict(
                  fixture=errors[0], result_written_ns=result_path.stat().st_mtime_ns,
                  receipt_written_ns=receipt.stat().st_mtime_ns,
                  disposition='Retained complete samples; zero-byte write after successful probe and window closure.'))
runs.append(result)
manifest['continuation'] = dict(
    after_run='2-splits-load-ghostty',
    reason='Classify a zero-byte PTY write as EPIPE so successful post-probe closure is handled like EIO/EPIPE.',
    fixture_sha256=hashlib.sha256(Path('/tmp/tgb-harness-closure/terminal_bench_fixture.py').read_bytes()).hexdigest(),
    resume_script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
(root / 'continuation.json').write_text(json.dumps(manifest['continuation'], indent=2) + '\n')
(root / 'runs.json').write_text(json.dumps(runs, indent=2) + '\n')
options = SimpleNamespace(samples=100, input_method='key', viewport=[1000, 700],
                          vsync='true', panes=4, throughput=False, float_windows=True)
setup = (Path('/tmp/tgb-release/bin/telar').resolve(), root / 'GhosttyProbe.app',
         root / 'probe.dylib', root / 'config.lua', options)
seen = {(r['round'], r['case'], r['mode']) for r in runs}
for round_index in range(4):
    order = ['ghostty', 'gui'] if round_index in (0, 3) else ['gui', 'ghostty']
    for case in manifest['cases']:
        options.case = case
        for mode in order:
            if (round_index, case, mode) in seen:
                continue
            result = measure(mode, root / f'{round_index}-{case}-{mode}', setup)
            result.update(round=round_index, fixture_sha256=manifest['continuation']['fixture_sha256'])
            runs.append(result)
            (root / 'runs.json').write_text(json.dumps(runs, indent=2) + '\n')
report = dict(manifest=manifest, runs=runs, rejected_startups=[], aggregate={
    f'{case}/{mode}': summarize([v for r in runs if r['case'] == case and r['mode'] == mode
                               for v in r['gpu_ms'][WARMUP:]])
    for case in manifest['cases'] for mode in ['ghostty', 'gui']})
(root / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report['aggregate'], indent=2), flush=True)
