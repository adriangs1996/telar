#!/usr/bin/env python3
"""Diagnostic ladder; these layer removals are not product optimizations."""
import argparse
import ctypes
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import time
from bench_control_queries import RemoteLibrary, process_snapshot


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--diagnostic', type=Path, required=True)
    parser.add_argument('--application', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    before, compilers = process_snapshot()
    if compilers:
        raise RuntimeError('Builds invalidate timing: '+repr(compilers))
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    layers = ['direct', 'state', 'media', 'engine', 'engine_without_drain']
    image = ctypes.CDLL(str(args.diagnostic.resolve()))
    digest = image.query_probe_ordinary_digest
    digest.restype = ctypes.c_uint64
    checks = []
    for size in [14, 112, 448, 3584]:
        data = b'ordinary text '*(size//14)
        for fragment in [0, 1, 112]:
            for iterations in [1, 10, 256]:
                values = {}
                for layer in layers:
                    function = getattr(image, 'query_probe_benchmark_component_'+layer)
                    function.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t]
                    function.restype = ctypes.c_uint64
                    if function(data, len(data), iterations, fragment) == 0:
                        raise RuntimeError('Layer rejected valid ordinary input')
                    values[layer] = digest()
                if len(set(values.values())) != 1:
                    raise RuntimeError('Layer screen/cursor mismatch: '+repr(values))
                checks.append({'bytes':size, 'fragment':fragment, 'iterations':iterations, 'digests':values})
    libraries = {layer:RemoteLibrary(args.diagnostic, True) for layer in layers}
    libraries['application'] = RemoteLibrary(args.application, False)
    functions = {layer:library.function('' if layer == 'application' else '_'+layer) for layer,library in libraries.items()}
    results = {}
    pairs = [('direct','state'), ('state','media'), ('media','engine'), ('engine','engine_without_drain'), ('application','direct'), ('application','engine')]
    try:
        for size,fragment in [(3584,0),(448,0),(448,112)]:
            data = b'ordinary text '*(size//14)
            for baseline,candidate in pairs:
                selected = {'baseline':functions[baseline], 'candidate':functions[candidate]}
                calibration = max(function(data,len(data),1000,fragment) for function in selected.values())
                iterations = max(100, min(500000, int(1000*40000000/calibration)))
                for function in selected.values():
                    warmup = time.monotonic_ns()
                    while time.monotonic_ns()-warmup < 150000000:
                        if function(data,len(data),iterations,fragment) == 0:
                            raise RuntimeError('Warmup failed')
                samples = []
                for pair in range(7):
                    order = ['baseline','candidate'] if pair%2 == 0 else ['candidate','baseline']
                    sample = {'order':order, 'load':os.getloadavg()}
                    for name in order:
                        function = selected[name]
                        duration = function(data,len(data),iterations,fragment)
                        if duration == 0:
                            raise RuntimeError('Timed call failed')
                        sample[name] = duration/iterations
                        sample[name+'_metrics'] = dict(function.last_metrics)
                    samples.append(sample)
                ratios = [sample['candidate']/sample['baseline'] for sample in samples]
                logs = [math.log(ratio) for ratio in ratios]
                middle = statistics.mean(logs)
                half = 2.447*statistics.stdev(logs)/math.sqrt(7)
                key = f'{size}-fragment{fragment}-{candidate}-vs-{baseline}'
                results[key] = {'baseline':baseline,'candidate':candidate,'bytes':size,'fragment':fragment,'iterations':iterations,'median_ratio':statistics.median(ratios),'ci95':[math.exp(middle-half),math.exp(middle+half)],'candidate_wins':sum(ratio<1 for ratio in ratios),'samples_ns_per_input':samples}
                print(key, round(statistics.median(ratios),3), flush=True)
    finally:
        for library in libraries.values():
            library.close()
    after, compilers = process_snapshot()
    report = {'started_at':started,'finished_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'host_before':before,'host_after':after,'compilers_after':compilers,'hashes':{str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in [args.diagnostic,args.application,Path(__file__),Path(__file__).parents[1]/'measurements/control-queries/experimental/ordinary_layers.cpp']},'scope':'Diagnostics of ordinary ASCII on the same VT/configuration/allocator/empty-drain fixture. No product acceptance or attribution to a particular syscall. Digest covers active packed cells and cursor, not scrollback. RSS includes setup. Native ARM64 only. Separate persistent processes.','warmup_minimum_wall_ns':150000000,'pairs':7,'digest_checks':checks,'results':results}
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    if compilers:
        raise RuntimeError('Concurrent build invalidated timing')


if __name__ == '__main__':
    main()
