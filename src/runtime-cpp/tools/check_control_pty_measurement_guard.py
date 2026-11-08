#!/usr/bin/env python3
"""Reproduce a compiler appearing at the last snapshot, without timing a runtime."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

import bench_control_pty as bench


def check(late_build):
    with tempfile.TemporaryDirectory(prefix='telar-control-guard-') as directory:
        root = Path(directory)
        artifact = root / 'synthetic-artifact'
        artifact.write_bytes(b'Never executed; only used for artifact hashing')
        output = root / 'report.json'
        calls = 0
        original = bench.subprocess.check_output

        def snapshot(arguments, **kwargs):
            nonlocal calls
            if arguments != ['ps', '-Ao', 'comm,%cpu']:
                return original(arguments, **kwargs)
            calls += 1
            return 'COMM %CPU\n' + ('zig 97.7\n' if late_build and calls == 30 else 'Python 0.0\n')

        def sample(*args, **kwargs):
            return {'cases': {'synthetic': {'roundtrip_ns': [100, 100, 100]}},
                    'saturation': {'queries': 5000, 'received': 5000},
                    'synthetic_sample_marker': 'must survive final validation failure'}

        argv = ['bench_control_pty.py', '--native', str(artifact), '--baseline', str(artifact),
                '--probe', str(artifact), '--output', str(output), '--pairs', '7']
        failure = None
        with patch.object(sys, 'argv', argv), patch.object(bench.subprocess, 'check_output', snapshot), patch.object(bench, 'run', sample), contextlib.redirect_stdout(io.StringIO()):
            try:
                bench.main()
            except RuntimeError as error:
                failure = str(error)
        assert bool(failure) == late_build
        assert calls == 30
        result = json.loads(output.read_text())
        assert result['valid_timing'] == (not late_build)
        assert len(result['pairs']) == 7
        for pair in result['pairs']:
            for variant in ['native', 'baseline']:
                assert pair[variant]['synthetic_sample_marker'] == 'must survive final validation failure'
                assert pair[variant]['cases']['synthetic']['roundtrip_ns'] == [100, 100, 100]
        assert result['summary']['synthetic']['status'] == ('invalid_concurrent_build' if late_build else 'equivalent_within_5_percent')
        if late_build:
            assert 'raw samples preserved' in failure
            assert 'zig 97.7' in result['processes_after']


if __name__ == '__main__':
    check(False)
    check(True)
    print(json.dumps({'synthetic_cases': 2, 'late_build_raw_pairs_preserved': 7,
                      'actual_runtime_executed': False, 'timing_claim': False}))
