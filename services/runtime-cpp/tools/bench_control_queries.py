#!/usr/bin/env python3
"""Alternating, real-handler component timings. Partial results are not acceptance."""
import argparse
import atexit
import ctypes
import datetime
import hashlib
import json
import math
import multiprocessing
import os
import resource
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
    'checksum-ascii-screen': (b'\x1b[1;1;1;1;24;80*y', 1, 0),
    'checksum-styled-screen': (b'\x1b[1;1;1;1;24;80*y', 1, 0),
    'checksum-grapheme-screen': (b'\x1b[1;1;1;1;24;80*y', 1, 0),
    'unknown-long': (b'\x1bP+q'+b'BAD;'*2048+b'\x1b\\', 1, 0),
    'graphics-payload': (b'\x1b_Ga=q,i=9,s=128,v=64;'+b'AAAA'*10922+b'AAA=\x1b\\', 1, 0),
}


def bind(path, component=False, suffix=""):
    library = ctypes.CDLL(str(path))
    symbol = 'query_probe_benchmark_component' if component else 'query_probe_benchmark'
    fn = getattr(library, symbol + suffix)
    fn.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t]
    fn.restype = ctypes.c_uint64
    return fn


def benchmark_worker(connection, path, component):
    functions = {}
    try:
        connection.send({'ready': True, 'pid': os.getpid()})
        while (request := connection.recv()) is not None:
            data, iterations, fragment, suffix = request
            if suffix not in functions:
                functions[suffix] = bind(path, component, suffix)
            cpu_started = time.process_time_ns()
            wall_started = time.monotonic_ns()
            duration = functions[suffix](data, len(data), iterations, fragment)
            connection.send({'duration': duration,
                             'wall_ns': time.monotonic_ns() - wall_started,
                             'cpu_ns': time.process_time_ns() - cpu_started,
                             'process_maxrss': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})
    except BaseException as failure:
        connection.send({'error': repr(failure)})
    finally:
        connection.close()


class RemoteFunction:
    def __init__(self, library, suffix):
        self.library = library
        self.suffix = suffix
        self.last_metrics = {}

    def __call__(self, data, length, iterations, fragment):
        if length != len(data):
            raise ValueError('Remote benchmark input length mismatch')
        self.library.connection.send((data, iterations, fragment, self.suffix))
        try:
            result = self.library.connection.recv()
        except EOFError as failure:
            raise RuntimeError('Benchmark worker exited unexpectedly') from failure
        if 'error' in result:
            raise RuntimeError(result['error'])
        self.last_metrics = result
        return result['duration']


class RemoteLibrary:
    def __init__(self, path, component):
        context = multiprocessing.get_context('spawn')
        self.connection, child = context.Pipe()
        self.process = context.Process(target=benchmark_worker, args=(child, path.resolve(), component))
        self.process.start()
        child.close()
        ready = self.connection.recv()
        if not ready.get('ready'):
            raise RuntimeError(str(ready))
        atexit.register(self.close)

    def function(self, suffix):
        return RemoteFunction(self, suffix)

    def close(self):
        if self.process.is_alive():
            try:
                self.connection.send(None)
            except (BrokenPipeError, EOFError, OSError):
                pass
            self.process.join(timeout=2)
            if self.process.is_alive():
                self.process.terminate()
                self.process.join()
        self.connection.close()


def process_snapshot():
    snapshot = subprocess.check_output(['ps', '-Ao', 'comm,%cpu'], text=True)
    compilers = []
    for line in snapshot.splitlines()[1:]:
        fields = line.rsplit(None, 1)
        if len(fields) == 2 and Path(fields[0]).name in {'clang', 'clang++', 'zig', 'ninja', 'ld', 'cc1', 'cc1plus'}:
            compilers.append(line.strip())
    return snapshot, compilers


def main():
    args = argparse.ArgumentParser()
    args.add_argument('--native', type=Path, default=NATIVE)
    args.add_argument('--reference', type=Path, default=GHOSTTY)
    args.add_argument('--component', action='store_true')
    args.add_argument('--in-process', action='store_true', help='Historical exploratory mode; default isolates each library in its own persistent process')
    args.add_argument('--reference-component', action='store_true')
    args.add_argument('--output', type=Path, required=True)
    args.add_argument('--case', action='append', choices=WORKLOADS)
    args = args.parse_args()
    results = {}
    before, compilers = process_snapshot()
    if compilers:
        raise RuntimeError('Concurrent build processes invalidate timing: '+repr(compilers))
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    harness_sha256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    native_library = None if args.in_process else RemoteLibrary(args.native, args.component)
    reference_library = None if args.in_process else RemoteLibrary(args.reference, args.reference_component)
    for name, (data, count, fragment) in WORKLOADS.items():
        if args.case and name not in args.case:
            continue
        suffix = {'checksum-ascii-screen':'_checksum_ascii','checksum-styled-screen':'_checksum_styled','checksum-grapheme-screen':'_checksum_graphemes'}.get(name, '_checksum' if name.startswith('checksum-') else '')
        native = bind(args.native,args.component,suffix) if args.in_process else native_library.function(suffix)
        reference = bind(args.reference,args.reference_component,suffix) if args.in_process else reference_library.function(suffix)
        calibration = max(native(data,len(data),1000,fragment), reference(data,len(data),1000,fragment))
        if not calibration:
            raise RuntimeError('Benchmark failed: '+name)
        warmup_iterations = max(100, min(5_000_000, int(1000*100_000_000/calibration)))
        for fn in [native, reference]:
            warmup_started = time.monotonic_ns()
            while time.monotonic_ns() - warmup_started < 150_000_000:
                if not fn(data,len(data),warmup_iterations,fragment):
                    raise RuntimeError('Warmup failed: '+name)
        calibration = max(native(data,len(data),1000,fragment), reference(data,len(data),1000,fragment))
        iterations = max(100, min(500000, int(1000*40_000_000/calibration)))
        samples = []
        for pair in range(7):
            order = [('native',native),('reference',reference)] if pair%2==0 else [('reference',reference),('native',native)]
            sample = {'order':[label for label,_ in order], 'load':os.getloadavg()}
            for label, fn in order:
                cpu_started = time.process_time_ns()
                wall_started = time.monotonic_ns()
                duration = fn(data,len(data),iterations,fragment)
                invocation_wall = time.monotonic_ns() - wall_started
                invocation_cpu = time.process_time_ns() - cpu_started
                if not args.in_process:
                    invocation_wall = fn.last_metrics['wall_ns']
                    invocation_cpu = fn.last_metrics['cpu_ns']
                    sample[label+'_process_maxrss'] = fn.last_metrics['process_maxrss']
                sample[label+'_invocation_wall_ns'] = invocation_wall
                sample[label+'_invocation_cpu_ns'] = invocation_cpu
                if not duration:
                    raise RuntimeError('Benchmark failed: '+name+' '+label)
                sample[label] = duration/(iterations*count)
            samples.append(sample)
        ratios = [s['native']/s['reference'] for s in samples]
        logs = [math.log(r) for r in ratios]
        mean = statistics.mean(logs)
        half = 2.447*statistics.stdev(logs)/math.sqrt(7)
        ci = [math.exp(mean-half),math.exp(mean+half)]
        results[name] = {'setup':{'checksum-ascii-screen':'80x24 A cells','checksum-styled-screen':'80x24 alternating bold italic A / default B','checksum-grapheme-screen':'80x24 A+U0301; no_trim flag4'}.get(name,'initial empty terminal'),'input_sha256':hashlib.sha256(data).hexdigest(),'bytes_per_iteration':len(data),'responses_or_units':count,'iterations':iterations,'fragment':fragment,'samples_ns_per_unit':samples,'native_wins':sum(r<1 for r in ratios),'median_ratio':statistics.median(ratios),'ratio_95pct_t_interval':ci,'status':'regression' if ci[0]>1.05 else 'improvement' if ci[1]<0.95 else 'equivalent_within_5_percent' if ci[0]>=0.95 and ci[1]<=1.05 else 'inconclusive'}
        print(name,round(statistics.median(ratios),3),results[name]['native_wins'],flush=True)
    if native_library is not None:
        native_library.close()
        reference_library.close()
    after, compilers_after = process_snapshot()
    report = {'host_processes_before':before,'host_processes_after':after,'concurrent_builds_after':compilers_after,'no_build_processes_observed_at_snapshots':not compilers_after,'harness_sha256':harness_sha256,'libraries_in_separate_persistent_processes':not args.in_process,'rss_scope':'Whole child-process lifetime high-water mark, including its one library and fixture; not incremental per-query memory.','warmup_minimum_wall_ns_per_variant_per_case':150_000_000,'cpu_scope':'Process CPU and wall around each full FFI invocation include untimed fixture setup/destruction; sample ns/unit uses the internal timer around stream processing only.','started_at':started,'finished_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Exploratory throughput. Coverage, desktop integration, allocation accounting and PTY latency are NOT certified.', 'command':sys.argv,'native_component_only':args.component,'reference_component_only':args.reference_component,'reference_kind':'native_previous_variant' if args.reference_component else 'ghostty_application_handler','comparison_margin':0.05,'pairs':7,'acceptance_rule':'Target wins at least 6/7; no untargeted workload loses consistently (0-1 wins) without verified identical normalized assembly.','architecture':'macOS ARM64 native','hashes':{str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in [args.native,args.reference]},'source_sha':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'working_tree_dirty':bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT)),'results':results}
    args.output.write_text(json.dumps(report,indent=2)+'\n')

if __name__=='__main__':
    main()
