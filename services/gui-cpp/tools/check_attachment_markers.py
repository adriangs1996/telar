import argparse
import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess


WORD = struct.Struct('<Q')
UUID = '12345678-1234-ABCD-1234-123456789abc'
PATH = '/tmp/pi-clipboard-' + UUID + '.png'


def fixtures():
    cases = []

    def case(name, columns=80, rows=4, texts=(), cursor=(0, 0), visible=True, number=1, wrapping=False, mutations=()):
        cells = [(b' ', 1, 0) for _ in range(columns * rows)]
        for x, y, text in texts:
            for character in text:
                if wrapping and x >= columns - 1:
                    x = 0
                    y += 1
                if y >= rows or x >= columns:
                    break
                cells[y * columns + x] = (character.encode('utf-8'), 1, 0)
                x += 1
        for x, y, payload, width, flags in mutations:
            cells[y * columns + x] = (payload, width, flags)
        cases.append((name, columns, rows, cursor, visible, number, cells))

    for number in (0, 1, 7, 65535, 65536):
        text = '[Image #' + str(number) + ']'
        for visible in (False, True):
            for cursor in (0, len(text), len(text) + 1, 140):
                case('number-%d-%s-%d' % (number, visible, cursor), columns=160, texts=((0, 0, text),), cursor=(cursor, 0), visible=visible, number=min(number, 65535))
    for text in ('[Image #01]', '[Image #0001]', '[Image #]', '[Image #+1]', '[Image#1]', '[image #1]', '[Image #655350]', '[Image #1a]'):
        case('malformed-' + text, texts=((0, 0, text),), cursor=(len(text), 0))
    for columns in (6, 7, 8, 9, 10, 32, 80):
        case('wrapped-%d' % columns, columns=columns, texts=((columns - 6, 0, '[Image'), (1, 1, '#1]')), cursor=(min(4, columns), 1))
    for distance in (119, 120, 121, 122):
        case('navigation-%d' % distance, columns=300, texts=((0, 0, '[Image #1]'),), cursor=(10 + distance, 0))
    case('atomic-middle-placeholder', columns=300, texts=((0, 0, '[Image #1] [Image #2]'),), cursor=(19, 0))
    case('repeated-history-marker', texts=((0, 0, '[Image #1]'), (3, 2, '[Image #1]')), cursor=(13, 2))
    for path in (PATH, PATH + 'x', PATH[:-3] + 'PNG', PATH.replace('ABCD', 'ABCz'), PATH.replace('.png', '.jpg'), PATH.replace('.png', '.webp'), PATH.replace('.png', '.gif'), '/' + 'a' * 600 + PATH):
        for visible in (False, True):
            case('path-%s-%s' % (path, visible), columns=1024, rows=2, texts=((0, 0, path),), cursor=(len(path), 0), visible=visible, mutations=() if visible else ((len(path), 0, b' ', 1, 16),))
    for columns in (2, 9, 17, 31, 60):
        logical = len(PATH)
        x, y = logical % (columns - 1), logical // (columns - 1)
        if y >= 16:
            continue
        case('force-wrapped-path-%d' % columns, columns=columns, rows=16, texts=((0, 0, PATH),), cursor=(x, y), wrapping=True)
    for duplicates in (False, True):
        texts = []
        for index in range(10):
            identity = UUID if duplicates else ('%08x' % index) + UUID[8:]
            texts.append((0, index, '/tmp/pi-clipboard-' + identity + '.png'))
        case('path-collection-%s' % duplicates, columns=80, rows=12, texts=texts, cursor=(len(PATH), 9))
    for width in (0, 1, 2):
        case('numeric-cell-width-%d' % width, texts=((0, 0, '[Image #1]'),), cursor=(10, 0), mutations=((0, 0, b'[', width, 0),))
    for visible in (False, True):
        case('backslash-%s' % visible, texts=((0, 0, 'word\\'),), cursor=(5, 0), visible=visible, mutations=() if visible else ((5, 0, b' ', 1, 16),))
        case('multiple-inverse-%s' % visible, texts=((0, 0, 'word\\'),), cursor=(5, 0), visible=visible, mutations=((5, 0, b' ', 1, 16), (6, 0, b' ', 1, 16)))
    rng = random.Random(732451)
    alphabet = ' [Image#]0123456789abcdefABCDEF-./tmp_clipboardxyz'
    for index in range(2048):
        columns = rng.choice((1, 2, 6, 9, 10, 17, 32, 80, 160, 300))
        rows = rng.choice((1, 2, 4, 8))
        texts = [(0, row, ''.join(rng.choice(alphabet) for _ in range(columns))) for row in range(rows)]
        if columns >= 10:
            selected = rng.randrange(rows)
            text = rng.choice(('[Image #1]', '[Image #7]', PATH))
            texts.append((rng.randrange(max(1, columns - min(columns, len(text)) + 1)), selected, text))
        x, y = rng.randrange(columns + 1), rng.randrange(rows)
        mutations = []
        for _ in range(rng.randrange(4)):
            mutations.append((rng.randrange(columns), rng.randrange(rows), rng.choice((b' ', b'\\', '界'.encode(), b'')), rng.randrange(3), rng.choice((0, 16))))
        case('random-%d' % index, columns, rows, texts, (x, y), bool(rng.randrange(2)), rng.choice((0, 1, 7, 65535)), mutations=mutations)
    return cases


def encode(cases):
    data = bytearray()
    for name, columns, rows, cursor, visible, number, cells in cases:
        data.append(1)
        for value in (columns, rows, *cursor, visible, number):
            data += WORD.pack(value)
        for text, width, flags in cells:
            for value in (len(text), width, flags, *text):
                data += WORD.pack(value)
    return data


def observations(data, cases):
    offset = 0

    def read():
        nonlocal offset
        value = WORD.unpack_from(data, offset)[0]
        offset += WORD.size
        return value

    def numeric():
        return [read() for _ in range(5)] if read() else None

    def plan():
        kind = read()
        return [kind] + ([read(), read()] if kind == 1 else [read() for _ in range(5)] if kind == 2 else [])

    records = []
    for case in cases:
        markers = []
        while (marker := numeric()) is not None:
            markers.append(marker)
        closest = numeric()
        flags = [read() for _ in range(5)]
        numeric_plan = plan()
        paths = [[read() for _ in range(44)] for _ in range(read())]
        path_plan = plan()
        records.append(dict(name=case[0], markers=markers, closest=closest, flags=flags, numeric_plan=numeric_plan, paths=paths, path_plan=path_plan))
    assert offset == len(data), 'Unexpected trailing observations'
    return records


def main():
    parser = argparse.ArgumentParser(description='Compare original and port marker scans, cursor boundaries, editor steps and navigation plans')
    parser.add_argument('--cpp', type=Path, required=True)
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args()
    options.output.mkdir(parents=True, exist_ok=False)
    cases = fixtures()
    payload = encode(cases)
    (options.output / 'input.bin').write_bytes(payload)
    results = {'cases': len(cases), 'input_sha256': hashlib.sha256(payload).hexdigest(), 'executions': {}}
    outputs = {}
    for name, executable in (('cpp', options.cpp.resolve()), ('zig', options.zig.resolve())):
        with (options.output / 'input.bin').open('rb') as source, (options.output / (name + '.bin')).open('wb') as destination, (options.output / (name + '.stderr')).open('wb') as error:
            process = subprocess.run([str(executable)], stdin=source, stdout=destination, stderr=error)
        data = (options.output / (name + '.bin')).read_bytes()
        results['executions'][name] = dict(exit_code=process.returncode, binary_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(), bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
        (options.output / 'results.json').write_text(json.dumps(results, indent=2))
        process.check_returncode()
        outputs[name] = data
        (options.output / (name + '-observations.json')).write_text(json.dumps(observations(data, cases), indent=2))
    assert outputs['cpp'] == outputs['zig'], 'Original and port marker observations differ'
    results['byte_exact'] = True
    (options.output / 'results.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
