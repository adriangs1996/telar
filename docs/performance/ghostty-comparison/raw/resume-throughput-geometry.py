import hashlib
import json
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, '/tmp/tgb-harness-geometry')
from gui_tui_latency import measure, summarize, WARMUP

root = Path('/tmp/tgb-v4-throughput').resolve()
manifest = json.loads((root / 'manifest.json').read_text())
runs = json.loads((root / 'runs.json').read_text())
failed = root / '1-single-ghostty'
assert not (failed / 'result.json').exists() and not (failed / 'throughput.json').exists()
receipts = [json.loads(p.read_text()) for p in (failed / 'receipts').glob('*.json')]
assert len(receipts) == 1 and 'did not confirm the viewport' in receipts[0]['error']
continuation = dict(
    after_run='1-single-gui-retry1', failed_setup='1-single-ghostty',
    failed_setup_receipts=receipts, failed_setup_log=(failed / 'result.json.log').read_text(),
    reason='Refresh marker coordinates when the window manager changed the texture dimensions before resize setup.',
    fixture_sha256=hashlib.sha256(Path('/tmp/tgb-harness-geometry/terminal_bench_fixture.py').read_bytes()).hexdigest(),
    probe_source_sha256=hashlib.sha256(Path('/tmp/tgb-harness-geometry/gui_tui_latency.m').read_bytes()).hexdigest(),
    resume_script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
manifest['continuations'] = [json.loads((root / 'continuation.json').read_text()), continuation]
(root / 'continuation-geometry.json').write_text(json.dumps(continuation, indent=2) + '\n')
options = SimpleNamespace(samples=1, input_method='key', viewport=[1000, 700],
                          vsync='true', panes=4, throughput=True, float_windows=True, case='single')
setup = (Path('/tmp/tgb-release/bin/telar').resolve(), root / 'GhosttyProbe.app',
         Path('/tmp/tgb-geometry-fixed.dylib'), root / 'config.lua', options)
seen = {(r['round'], r['mode']) for r in runs}
for round_index in range(6):
    order = ['ghostty', 'gui'] if round_index in (0, 3, 4) else ['gui', 'ghostty']
    for mode in order:
        if (round_index, mode) in seen:
            continue
        name = f'{round_index}-single-{mode}' + ('-retry1' if round_index == 1 and mode == 'ghostty' else '')
        result = measure(mode, root / name, setup)
        result.update(round=round_index, fixture_sha256=continuation['fixture_sha256'],
                      probe_source_sha256=continuation['probe_source_sha256'], attempt_directory=name)
        runs.append(result)
        (root / 'runs.json').write_text(json.dumps(runs, indent=2) + '\n')
report = dict(manifest=manifest, runs=runs, rejected_startups=[], aggregate={
    f'single/{mode}': summarize([v for r in runs if r['mode'] == mode for v in r['gpu_ms'][WARMUP:]])
    for mode in ['ghostty', 'gui']})
(root / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
print('Six native throughput rounds completed.', flush=True)
