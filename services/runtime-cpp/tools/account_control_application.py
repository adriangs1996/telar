#!/usr/bin/env python3
"""Count frozen application allocator requests and explicit response sink copies."""
import argparse
import ctypes
import datetime
import hashlib
import json
import multiprocessing
from pathlib import Path
import platform

from account_control_queries import verify_output
from bench_control_queries import WORKLOADS


PHASE_FIELDS = [
    'sink_copy_bytes', 'alloc_calls', 'alloc_bytes', 'alloc_successes',
    'resize_calls', 'resize_bytes', 'resize_successes',
    'remap_calls', 'remap_bytes', 'remap_successes',
    'free_calls', 'free_bytes', 'live_begin', 'live_end', 'peak_live',
]


class Phase(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint64) for name in PHASE_FIELDS]


class Options(ctypes.Structure):
    _fields_ = [(name, ctypes.c_size_t) for name in ['iterations', 'fragment', 'setup', 'warmup']]


class Report(ctypes.Structure):
    _fields_ = [('version', ctypes.c_size_t), ('phase_count', ctypes.c_size_t),
               ('sink_copy_bytes', ctypes.c_uint64), ('output_fnv1a', ctypes.c_uint64),
               ('phases', Phase * 5)]


def verification_worker(connection, library):
    try:
        while (request := connection.recv()) is not None:
            data, iterations, fragment, setup, warmup = request
            connection.send(verify_output(library, data, iterations, fragment, setup, warmup))
    except BaseException as error:
        connection.send({'error': repr(error)})
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--application', type=Path, required=True)
    parser.add_argument('--verify-library', type=Path, required=True)
    parser.add_argument('--native-accounting', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--iterations', type=int, default=100)
    parser.add_argument('--warmup', type=int, default=100)
    parser.add_argument('--case', action='append', choices=WORKLOADS)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 100000 or not 0 <= args.warmup <= 100000:
        parser.error('Accounting iterations exceed the adapter limits')
    library = ctypes.CDLL(str(args.application.resolve()))
    layout = library.query_probe_accounting_layout
    layout.argtypes = [ctypes.POINTER(ctypes.c_size_t), ctypes.c_size_t]
    layout.restype = ctypes.c_size_t
    actual = (ctypes.c_size_t * 6)()
    expected_layout = [ctypes.sizeof(Options), ctypes.sizeof(Report), ctypes.sizeof(Phase),
                       Report.phases.offset, Report.output_fnv1a.offset, Phase.sink_copy_bytes.offset]
    if layout(actual, len(actual)) != len(actual) or list(actual) != expected_layout:
        raise RuntimeError('Accounting FFI layout differs from compiled application')
    measure = library.query_probe_accounting
    measure.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(Options), ctypes.POINTER(Report)]
    measure.restype = ctypes.c_bool
    native = json.loads(args.native_accounting.read_text())
    if native['iterations'] != args.iterations:
        raise RuntimeError('Native and application iteration counts must match')
    results = {}
    failure = None
    context = multiprocessing.get_context('spawn')
    connection, child_connection = context.Pipe()
    worker = context.Process(target=verification_worker, args=(child_connection, args.verify_library))
    worker.start()
    child_connection.close()
    try:
        for name, (data, units, fragment) in WORKLOADS.items():
            if args.case and name not in args.case:
                continue
            setup = {'checksum-ascii-screen': 2, 'checksum-styled-screen': 3,
                     'checksum-grapheme-screen': 4}.get(name, int(name.startswith('checksum-')))
            cases = {}
            results[name] = {'input_sha256': hashlib.sha256(data).hexdigest(), 'input_bytes': len(data),
                             'units_per_iteration': units, 'fragment': fragment, 'setup': setup, 'runs': cases}
            if native['results'][name]['input_sha256'] != results[name]['input_sha256']:
                raise RuntimeError('Native input differs: ' + name)
            for label, warmup in [('cold', 0), ('warm', args.warmup)]:
                native_case = native['results'][name]['runs'][label]
                if native_case['warmup_iterations'] != warmup:
                    raise RuntimeError('Retained-state warmup differs: ' + name)
                output = Report()
                options = Options(args.iterations, fragment, setup, warmup)
                success = measure(data, len(data), ctypes.byref(options), ctypes.byref(output))
                phases = [{field: getattr(phase, field) for field in PHASE_FIELDS} for phase in output.phases]
                result = {'completed': bool(success), 'version': output.version,
                          'phase_count': output.phase_count, 'phases': phases,
                          'sink_copy_bytes': output.sink_copy_bytes, 'output_fnv1a': output.output_fnv1a,
                          'warmup_iterations': warmup}
                cases[label] = result
                if not success or output.version != 1 or output.phase_count != 5 or phases[-1]['live_end']:
                    raise RuntimeError(f'Application accounting failed or retained ownership: {name}, {label}')
                if any(phase['alloc_calls'] != phase['alloc_successes'] for phase in phases):
                    raise RuntimeError(f'Application allocation failure invalidates this row: {name}, {label}')
                connection.send((data, args.iterations, fragment, setup, warmup))
                expected = connection.recv()
                if 'error' in expected:
                    raise RuntimeError(expected['error'])
                if any(result[key] != value for key, value in expected.items()):
                    raise RuntimeError(f'Instrumented application output differs from frozen application: {name}, {label}')
                result['output_verified_against_frozen_application'] = True
                result['native_workload'] = native_case['phases'][3]
                result['native_sink_copy_bytes'] = native_case['sink_copy_bytes']
                result['native_same_output_hash'] = native_case['output_fnv1a'] == result['output_fnv1a']
            print(name, cases['warm']['phases'][3]['alloc_calls'],
                  cases['warm']['phases'][3]['alloc_bytes'], flush=True)
    except Exception as error:
        failure = repr(error)
    finally:
        try:
            if worker.is_alive():
                connection.send(None)
        except (BrokenPipeError, EOFError, OSError) as error:
            if failure is None:
                failure = 'Owned verification connection failed: ' + repr(error)
        connection.close()
        worker.join(timeout=10)
        if worker.is_alive():
            worker.terminate()
            worker.join()
        if worker.exitcode and failure is None:
            failure = 'Owned verification process failed: ' + str(worker.exitcode)
    report = {'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'architecture': platform.machine(), 'iterations': args.iterations,
              'phases': ['setup', 'seed', 'warmup', 'workload', 'destroy'],
              'accounting_ffi_layout': expected_layout, 'completed': failure is None, 'failure': failure,
              'verification_in_separate_spawned_process': True,
              'scope': 'Allocator interface requests on the synchronous fixture thread; explicit queue-to-sink copies. No timing claim.',
              'limits': [
                  'Cold uses a fresh fixture and matches the benchmark invocation state; warm retains the same terminal and sink after fixed-iteration warmup.',
                  'Timing warmup instead invokes fresh fixtures; retained-state rows do not represent those timing intervals.',
                  'Direct VT page mappings, other threads, global IoThreaded and allocators outside the supplied allocator are excluded.',
                  'Live bytes are requested logical lengths, not physical malloc capacity or RSS.',
                  'Resize/remap sizes are complete requested lengths; failed resize/remap may be normal fallback, not allocation failure.',
                  'Requested bytes cannot be added together as copied bytes; internal message, realloc and ArrayList growth copies are excluded.',
                  'Native allocator requests have a different operation interface; counts are reported separately without an aggregate speed claim.',
              ],
              'hashes': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in
                         [args.application, args.verify_library, args.native_accounting, Path(__file__)]},
              'results': results}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    if failure:
        raise RuntimeError(failure)


if __name__ == '__main__':
    main()
