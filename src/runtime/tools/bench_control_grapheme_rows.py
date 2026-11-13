#!/usr/bin/env python3
"""Compare mixed UTF-8 row refresh plus checksum, including sparse/long chains."""
import hashlib
import json
from pathlib import Path
import bench_control_queries as benchmark


def main():
    benchmark.WORKLOADS.clear()
    for density in [1, 7, 8, 9, 16, 80]:
        for length in [1, 4, 32]:
            cluster = ''.join('\u0301' if index % 2 == 0 else '\u0327' for index in range(length)).encode()
            row = (b'A' + cluster) * density + b'A' * (80 - density)
            refresh = b'\x1b[H' + b'\r\n'.join([row] * 24)
            query = b'\x1b[7#y\x1b[9;1;1;1;24;80*y'
            benchmark.WORKLOADS[f'checksum-row-{density}-chain-{length}'] = (refresh + query, 1, 0)
    benchmark.main()
    import sys
    output = Path(sys.argv[sys.argv.index('--output') + 1])
    report = json.loads(output.read_text())
    report['row_fixture_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    report['row_scope'] = 'Timed work includes row refresh on every iteration, then a positive/no-attributes/no-trim checksum. Both variants receive identical UTF-8 and state changes. This is not an isolated checksum timing.'
    output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
