#!/usr/bin/env python3
"""Alternating, real-handler component timings. Partial results are not acceptance."""
import argparse
import ctypes
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time
from control_query_oracle import ROOT, GHOSTTY, NATIVE

WORKLOADS = {
    'operating-status': (b'\x1b[5n', 1, 0),
    'cursor': (b'\x1b[6n', 1, 0),
    'cursor-extended': (b'\x1b[?6n', 1, 0),
    'mode-report': (b'\x1b[?2004$p', 1, 0),
    'attributes': (b'\x1b[c', 1, 0),
    'style': (b'\x1bP$qm\x1b\\', 1, 0),
    'cursor-style': (b'\x1bP$q q\x1b\\', 1, 0),
    'termcap': (b'\x1bP+q436F\x1b\\', 1, 0),
    'palette': (b'\x1b]4;1;?\x1b\\', 1, 0),
    'palette-16': (b'\x1b]4;'+b';'.join(str(i).encode()+b';?' for i in range(16))+b'\x1b\\', 16, 0),
    'dynamic-colors': (b'\x1b]10;?;?;?\x1b\\', 3, 0),
    'keyboard': (b'\x1b[?u', 1, 0),
    'size': (b'\x1b[18t', 1, 0),
    'glyph-coverage': (b'\x1b_25a1;q;cp=e0a0\x1b\\', 1, 0),
    'graphics-query': (b'\x1b_Ga=q,i=9,s=1,v=1;AAAAAA==\x1b\\', 1, 0),
    'burst-32': (b'\x1b[5n'*32, 32, 0),
    'unknown': (b'\x1b[55555n\x1bP+qBAD\x1b\\', 1, 0),
    'cursor-byte-fragments': (b'\x1b[6n', 1, 1),
    'mixed': ((b'ordinary text '*8+b'\x1b[6n')*4, 4, 0),
    'ordinary': (b'ordinary text '*256, 1, 0),
    'checksum-small': (b'\x1b[1;1;1;1;1;5*y', 1, 0),
    'checksum-screen': (b'\x1b[1;1;1;1;24;80*y', 1, 0),
    'unknown-long': (b'\x1bP+q'+b'BAD;'*2048+b'\x1b\\', 1, 0),
    'graphics-payload': (b'\x1b_Ga=q,i=9,s=128,v=64;'+b'AAAA'*10922+b'AAA=\x1b\\', 1, 0),
}


def bind(path, component=False, checksum=False):
    library = ctypes.CDLL(str(path))
    symbol = 'query_probe_benchmark_component' if component else 'query_probe_benchmark'
    fn = getattr(library, symbol + ('_checksum' if checksum else ''))
    fn.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t]
    fn.restype = ctypes.c_uint64
    return fn


def main():
    args = argparse.ArgumentParser()
    args.add_argument('--native', type=Path, default=NATIVE)
    args.add_argument('--reference', type=Path, default=GHOSTTY)
    args.add_argument('--component', action='store_true')
    args.add_argument('--reference-component', action='store_true')
    args.add_argument('--output', type=Path, required=True)
    args.add_argument('--case', action='append', choices=WORKLOADS)
    args = args.parse_args()
    results = {}
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    for name, (data, count, fragment) in WORKLOADS.items():
        if args.case and name not in args.case:
            continue
        checksum = name.startswith('checksum-')
        native = bind(args.native,args.component,checksum)
        reference = bind(args.reference,args.reference_component,checksum)
        calibration = max(native(data,len(data),1000,fragment), reference(data,len(data),1000,fragment))
        if not calibration:
            raise RuntimeError('Benchmark failed: '+name)
        iterations = max(100, min(500000, int(1000*40_000_000/calibration)))
        samples = []
        for pair in range(7):
            order = [('native',native),('reference',reference)] if pair%2==0 else [('reference',reference),('native',native)]
            sample = {'order':[label for label,_ in order], 'load':os.getloadavg()}
            for label, fn in order:
                duration = fn(data,len(data),iterations,fragment)
                if not duration:
                    raise RuntimeError('Benchmark failed: '+name+' '+label)
                sample[label] = duration/(iterations*count)
            samples.append(sample)
        ratios = [s['native']/s['reference'] for s in samples]
        logs = [math.log(r) for r in ratios]
        mean = statistics.mean(logs)
        half = 2.447*statistics.stdev(logs)/math.sqrt(7)
        ci = [math.exp(mean-half),math.exp(mean+half)]
        results[name] = {'input_sha256':hashlib.sha256(data).hexdigest(),'bytes_per_iteration':len(data),'responses_or_units':count,'iterations':iterations,'fragment':fragment,'samples_ns_per_unit':samples,'native_wins':sum(r<1 for r in ratios),'median_ratio':statistics.median(ratios),'ratio_95pct_t_interval':ci,'status':'regression' if ci[0]>1.05 else 'improvement' if ci[1]<0.95 else 'equivalent_within_5_percent' if ci[0]>=0.95 and ci[1]<=1.05 else 'inconclusive'}
        print(name,round(statistics.median(ratios),3),results[name]['native_wins'],flush=True)
    report = {'started_at':started,'finished_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Exploratory throughput. Coverage, desktop integration, allocation accounting and PTY latency are NOT certified.', 'command':sys.argv,'native_component_only':args.component,'reference_component_only':args.reference_component,'reference_kind':'native_previous_variant' if args.reference_component else 'ghostty_application_handler','comparison_margin':0.05,'pairs':7,'acceptance_rule':'Target wins at least 6/7; no untargeted workload loses consistently (0-1 wins) without verified identical normalized assembly.','architecture':'macOS ARM64 native','hashes':{str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in [args.native,args.reference]},'source_sha':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'working_tree_dirty':bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT)),'results':results}
    args.output.write_text(json.dumps(report,indent=2)+'\n')

if __name__=='__main__':
    main()
