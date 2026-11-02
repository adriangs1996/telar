import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inspect_trace(trace):
    words = struct.unpack('<' + str(len(trace) // 8) + 'Q', trace)
    offset = 0
    operations = Counter()
    outcomes = Counter()
    markers = Counter()
    plans = Counter()
    limits = Counter()
    for index in range(16384):
        prefix = words[offset:offset + 17]
        assert len(prefix) == 17 and prefix[0] == index, 'Incomplete or reordered lifecycle record'
        operations[prefix[1]] += 1
        outcomes[prefix[3]] += 1
        offset += 17
        for _ in range(prefix[10]):
            number, path = words[offset:offset + 2]
            offset += 2
            if number:
                markers['number'] += 1
            if path:
                assert path == 1
                assert len(words[offset:offset + 36]) == 36
                assert all(byte <= 255 for byte in words[offset:offset + 36])
                offset += 36
                markers['path'] += 1
        plan = words[offset]
        offset += 1
        plans[plan] += 1
        assert plan in range(4), 'Invalid plan kind'
        if plan == 2:
            limit, requested = words[offset:offset + 2]
            assert limit in (1, 2, 3)
            limits[limit] += 1
            offset += 2
        elif plan == 3:
            direction, steps, deletion, count, keys = words[offset:offset + 5]
            assert direction in (0, 1) and deletion in (0, 1)
            assert keys == 2 * steps + count
            offset += 5
    assert offset == len(words), 'Trailing lifecycle observations'
    assert set(operations) == set(range(17)), 'Unexercised lifecycle operation'
    assert set(outcomes) == set(range(7)), 'Unexercised catalog outcome'
    assert markers['number'] and markers['path'] and plans[3], 'No learned marker or reachable removal coverage'
    return dict(records=16384, operations=dict(sorted(operations.items())), outcomes=dict(sorted(outcomes.items())), markers=dict(markers), plans=dict(sorted(plans.items())), limits=dict(sorted(limits.items())))


def main():
    parser = argparse.ArgumentParser(description='Compare full attachment catalog and marker lifecycle with unchanged original Zig sources')
    parser.add_argument('--cpp', type=Path, required=True)
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--require-limits', action='store_true')
    options = parser.parse_args()
    options.output.mkdir(parents=True, exist_ok=False)
    receipt = dict(binaries={}, executions={}, byte_exact=False)
    traces = {}
    result_path = options.output / 'results.json'
    for name, binary in (('cpp', options.cpp), ('zig', options.zig)):
        binary = binary.resolve()
        receipt['binaries'][name] = dict(path=str(binary), sha256=digest(binary))
        trace = options.output / (name + '.bin')
        with trace.open('wb') as output, (options.output / (name + '.stderr')).open('wb') as errors:
            result = subprocess.run([str(binary)], stdout=output, stderr=errors, timeout=120)
        receipt['executions'][name] = dict(exit_code=result.returncode, bytes=trace.stat().st_size, sha256=digest(trace))
        result_path.write_text(json.dumps(receipt, indent=2) + '\n')
        result.check_returncode()
        traces[name] = trace.read_bytes()
    assert traces['cpp'] == traces['zig'], 'Original and port lifecycle observations differ'
    receipt.update(inspect_trace(traces['cpp']))
    receipt['byte_exact'] = True
    result_path.write_text(json.dumps(receipt, indent=2) + '\n')
    if options.require_limits:
        assert set(receipt['limits']) == {1, 2, 3}, 'Missing navigation, path length or removal key quota coverage'
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
