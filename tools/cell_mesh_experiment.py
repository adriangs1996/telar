#!/usr/bin/env python3
"""Compare unchanged renderer semantics and paired baseline/candidate workloads."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
from types import SimpleNamespace

from dod_measure import execute, save
from echo_latency import percentile
import gui_tui_latency

ROOT = Path(__file__).resolve().parent.parent
VIEWPORT_REJECTION = 11
MAX_NATIVE_ATTEMPTS = 3


def read_rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def summarize(values):
    return dict(n=len(values), median=statistics.median(values),
                minimum=min(values), maximum=max(values),
                p95=percentile(values, .95), p99=percentile(values, .99))


def verify(options, output):
    frames = {}
    for name in ('baseline', 'candidate'):
        directory = output/name
        command = ['env', 'DOD_TERMINAL_ONLY=1', 'DOD_VERIFY=1', 'DOD_SAMPLES=32',
                   'DOD_WARMUP=0', getattr(options, name)/'telar-dod-probe']
        receipt = execute(command, directory)
        if receipt['status'] != 0:
            raise RuntimeError(f'{name} verification failed')
        frames[name] = [row for row in read_rows(directory/'stdout') if row['type']=='frame']
    if not frames['baseline'] or frames['baseline'] != frames['candidate']:
        raise RuntimeError('renderer quad/atlas digests differ; inspect retained per-frame evidence')
    save(output/'summary.json', dict(equal_frames=len(frames['baseline']),
         equivalence='SHA-256 of every emitted quad byte and complete glyph atlas for each frame',
         limits='Fixed deterministic fixture, complemented by renderer correctness tests; timings from verification are excluded.'))


def cpu(options, output):
    measured = {}
    for repetition in range(options.rounds):
        for mode in options.modes:
            for name in (('baseline','candidate') if repetition % 2 == 0 else ('candidate','baseline')):
                directory = output/f'{mode}-{repetition}-{name}'
                command = ['env', 'DOD_TERMINAL_ONLY=1', f'DOD_MODE={mode}', 'DOD_SAMPLES=10000',
                           'DOD_WARMUP_NS=5000000000', getattr(options, name)/'telar-dod-probe']
                receipt = execute(command, directory)
                if receipt['status'] != 0:
                    raise RuntimeError(f'{directory.name} failed')
                for row in read_rows(directory/'stdout'):
                    if row['type'] != 'workload':
                        continue
                    if row['iterations'] != 10000 or row['measured_allocations'] != 0:
                        raise RuntimeError(f'invalid completed work or allocation: {row}')
                    measured.setdefault(row['name'], {}).setdefault(name, []).append(row)
    comparison = []
    for name, builds in measured.items():
        reference = builds['baseline']
        candidate = builds['candidate']
        if any(a['last_frame_quads'] != b['last_frame_quads'] for a,b in zip(reference,candidate)):
            raise RuntimeError(f'{name}: final quad counts differ')
        timings = {label:[row['elapsed_ns']/row['iterations'] for row in rows] for label,rows in builds.items()}
        changes = [(b/a-1)*100 for a,b in zip(timings['baseline'],timings['candidate'])]
        comparison.append(dict(name=name, ns_per_draw={label:summarize(values) for label,values in timings.items()},
                               paired_change_percent=summarize(changes), raw_ns_per_draw=timings,
                               live_requested_bytes={label:[row['live_requested_bytes'] for row in rows] for label,rows in builds.items()},
                               measured_allocations=0))
    save(output/'summary.json', dict(comparison=comparison, gate='A repeatable CPU reduction beyond between-run variation, zero steady allocations and no full-redraw or input-tail regression.'))


def native(options, output):
    library = output/'pixel-probe.dylib'
    subprocess.run(['clang','-dynamiclib','-O2','-fobjc-arc','-framework','AppKit',
                    '-framework','QuartzCore','-framework','Metal',
                    str(ROOT/'tools/gui_tui_latency.m'),'-o',str(library)],check=True)
    settings = SimpleNamespace(samples=200, input_method='text', viewport=[1600,1000],
                               panes=options.panes, vsync='true', case='single' if options.panes == 1 else 'splits', throughput=False,
                               text_pattern='variable', background_mib_per_second=None, float_windows=True)
    results = []
    rejected = []
    for repetition in range(options.rounds):
        for attempt in range(MAX_NATIVE_ATTEMPTS):
            pair = []
            try:
                for name in (('baseline','candidate') if repetition % 2 == 0 else ('candidate','baseline')):
                    row = gui_tui_latency.measure('gui',output/f'{name}-{repetition}-attempt-{attempt}',
                            (getattr(options,name)/'telar',None,library,
                             ROOT/'docs/performance/ghostty-comparison/config.lua',settings))
                    row.update(build=name,repetition=repetition,attempt=attempt)
                    pair.append(row)
            except gui_tui_latency.ProbeFailure as error:
                rejected.append(dict(repetition=repetition,attempt=attempt,
                                     completed_builds=[row['build'] for row in pair],
                                     failed_build=name,result=error.result))
                save(output/'rejected.json',rejected)
                # Geometry drift invalidates a controlled comparison. Retry the
                # entire pair symmetrically; do not retry missing/wrong pixels.
                if error.result['failed'] != VIEWPORT_REJECTION or attempt + 1 == MAX_NATIVE_ATTEMPTS:
                    raise
                print('rejected geometry drift; repeating pair',repetition,flush=True)
                continue
            results.extend(pair)
            save(output/'runs.json',results)
            break
    geometries = {(tuple(row['viewport']), tuple(row['pty_cells']),
                   row['backing_scale'], row['display_max_fps']) for row in results}
    if len(geometries) != 1:
        raise RuntimeError('native campaign changed display geometry; do not pool its runs')
    summary = {}
    for name in ('baseline','candidate'):
        rows = [row for row in results if row['build']==name]
        summary[name] = dict(latency_ms=summarize([value for row in rows for value in row['gpu_ms'][row['warmup']:]]),
                             runs=[row['summary'] for row in rows],
                             rss_bytes=[row['host_max_rss_bytes'] for row in rows])
    save(output/'summary.json',summary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase',choices=['verify','cpu','native'])
    parser.add_argument('--baseline',required=True,type=Path)
    parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--rounds',type=int,default=5)
    parser.add_argument('--modes',nargs='+',default=['retained','sparse','full'])
    parser.add_argument('--panes',type=int,default=1)
    options = parser.parse_args()
    if not 1 <= options.rounds <= 10:
        parser.error('rounds must be 1..10')
    options.baseline = options.baseline.resolve()
    options.candidate = options.candidate.resolve()
    output = options.output.resolve()/options.phase
    output.mkdir(mode=0o700,parents=True,exist_ok=False)
    binaries = {f'{name}/{filename}':hashlib.sha256((getattr(options,name)/filename).read_bytes()).hexdigest()
                for name in ('baseline','candidate') for filename in ('telar','telar-dod-probe')}
    save(output/'manifest.json',dict(platform=platform.platform(),binaries=binaries,
         rounds=options.rounds,modes=options.modes,panes=options.panes,phase=options.phase,baseline=str(options.baseline),candidate=str(options.candidate),
         instrumentation='Both builds ReleaseFast; profile counts and timing disabled.',
         runner_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
         probe_sha256=hashlib.sha256((ROOT/'src/gui/ProfilingProbe.zig').read_bytes()).hexdigest(),
         power=subprocess.check_output(['pmset','-g','batt'],text=True)))
    {'verify':verify,'cpu':cpu,'native':native}[options.phase](options,output)


if __name__ == '__main__':
    main()
