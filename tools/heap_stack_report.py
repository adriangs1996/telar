"""Validate sampled heap-site evidence; never infer latency or live memory from it."""

import argparse
from collections import Counter
import json
from pathlib import Path

MASK = (1 << 64) - 1
APIS = ['malloc', 'calloc', 'realloc', 'aligned_alloc', 'posix_memalign']


def selected(ordinal, shift):
    value = ((ordinal ^ (ordinal >> 30)) * 0xbf58476d1ce4e5b9) & MASK
    value = ((value ^ (value >> 27)) * 0x94d049bb133111eb) & MASK
    return not ((value ^ (value >> 31)) & ((1 << shift) - 1))


def analyze(census):
    def integer(value, low=0, high=MASK):
        if type(value) is not int or not low <= value <= high:
            raise ValueError('Invalid heap counter')
        return value

    if (census.get('version') != 1 or census.get('clock') != 'CLOCK_UPTIME_RAW'
            or census.get('complete') is not True or type(census.get('sampling')) is not bool
            or census.get('overflow') != 0 or census.get('errors') != 0):
        raise ValueError('Incomplete or overflowing heap diagnostic')
    integer(census['version'], 1, 1)
    integer(census['overflow'], 0, 0)
    integer(census['errors'], 0, 0)
    integer(census['pid'], 1, 2**31 - 1)
    begin, end = integer(census['begin_ns'], 1), integer(census['end_ns'], 1)
    if begin > end:
        raise ValueError('Invalid heap interval')
    calls = integer(census['successful_calls'], 0, 10_000_000)
    byte_count = integer(census['requested_bytes'])
    integer(census['null_returns'])
    integer(census['free_calls'])
    shift = integer(census['sample_shift'], 0, 12)
    if census['api_names'] != APIS or len(census['api_calls']) != len(APIS):
        raise ValueError('Heap API contract changed')
    if sum(integer(value) for value in census['api_calls']) != calls:
        raise ValueError('Heap API counts do not sum to total')
    expected = [index for index in range(1, calls + 1) if selected(index, shift)] if census['sampling'] else []
    records = census['records']
    if integer(census['used'], 0, 8192) != len(records) or [record['ordinal'] for record in records] != expected:
        raise ValueError('Missing, extra or reordered heap samples')
    symbols = census['symbols']
    addresses, sampled_apis = set(), Counter()
    inclusive, leaves, images, threads = Counter(), Counter(), Counter(), Counter()
    previous, sampled_bytes = begin, 0
    observer = {'observe', 'count_malloc', 'count_calloc', 'count_realloc', 'count_aligned', 'count_posix_aligned'}
    for record in records:
        integer(record['ordinal'], 1, calls)
        at = integer(record['at_ns'], begin, end)
        if at < previous:
            raise ValueError('Heap timestamps are reordered')
        previous = at
        api = integer(record['api'], 0, len(APIS) - 1)
        sampled_apis[api] += 1
        sampled_bytes += integer(record['requested_bytes'])
        threads[integer(record['thread_id'], 1)] += 1
        if not 1 <= len(record['frames']) <= 24:
            raise ValueError('Invalid stack depth')
        names, stack_images = [], set()
        for address in record['frames']:
            if not isinstance(address, str) or not address.startswith('0x') or not 0 < int(address, 16) <= MASK:
                raise ValueError('Invalid instruction address')
            addresses.add(address)
            info = symbols[address]
            if type(info['resolved']) is not bool or not isinstance(info['image'], str) or not isinstance(info['symbol'], str):
                raise ValueError('Invalid stack symbol')
            for field in ('image_base', 'symbol_base'):
                if not isinstance(info[field], str) or not 0 <= int(info[field], 16) <= int(address, 16):
                    raise ValueError('Invalid symbol load address')
            if info['symbol'].lstrip('_') in observer:
                continue
            name = f'{Path(info["image"]).name}:{info["symbol"] or address}'
            names.append(name)
            stack_images.add(Path(info['image']).name or 'unresolved')
        inclusive.update(set(names))
        images.update(stack_images)
        if names:
            leaves[names[0]] += 1
    if addresses != set(symbols) or sampled_bytes > byte_count:
        raise ValueError('Heap sample partition mismatch')
    if any(value > census['api_calls'][api] for api, value in sampled_apis.items()):
        raise ValueError('Sampled API count exceeds total')
    return dict(successful_calls=calls, requested_bytes=byte_count, sampled_calls=len(records),
                sampled_requested_bytes=sampled_bytes, threads=dict(threads),
                depth_limited_samples=sum(len(record['frames']) == 24 for record in records),
                first_external_symbols=leaves.most_common(30), inclusive_symbols=inclusive.most_common(40),
                inclusive_images=images.most_common(),
                scope='Sampled call frequencies only; inclusive rows overlap. Observer frames excluded by name, native probe frames retained. No allocation CPU, net/live memory or exact population site counts.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('result', type=Path)
    options = parser.parse_args()
    print(json.dumps(analyze(json.loads(options.result.read_text())['heap_stack_census']), indent=2))
