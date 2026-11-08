import argparse
import hashlib
import json
from pathlib import Path
import subprocess


UNICODE_COUNT = 0x110000
OUTSIDE_UNICODE_COUNT = 3
EXPECTED_BYTES = UNICODE_COUNT // 8 + OUTSIDE_UNICODE_COUNT


def identity(path):
    path = path.resolve(strict=True)
    return dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def compare(expected, actual):
    if len(expected) != EXPECTED_BYTES or len(actual) != EXPECTED_BYTES:
        raise ValueError('Incomplete coverage bitmap or out-of-range results')
    if expected != actual:
        index = next(index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1])
        raise ValueError(f'Font coverage differs at output byte {index}')


def main():
    parser = argparse.ArgumentParser(description='Compare complete Face coverage before and after metrics, shaping and rasterization')
    parser.add_argument('reference', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--font', nargs=2, action='append', metavar=('PATH', 'VARIANT'),
                        help='Repeat for custom font files; VARIANT is regular or wide')
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    cases = options.font or [
        (root / 'assets' / name, 'regular') for name in
        ('IBMPlexSans-Regular.ttf', 'IBMPlexSans-SemiBold.ttf', 'JetBrainsMono-Regular.ttf', 'SymbolsNerdFontMono-Regular.ttf')
    ] + [(root / 'services/gui-cpp/tests/fixtures/metrics-variable.ttf', variant) for variant in ('regular', 'wide')]
    cases = [(Path(path), variant) for path, variant in cases]
    if any(variant not in ('regular', 'wide') for _, variant in cases):
        parser.error('font variants must be regular or wide')
    manifest = dict(binaries={name: identity(path) for name, path in
                              (('reference', options.reference), ('candidate', options.candidate))},
                    fonts=[dict(**identity(path), variant=variant) for path, variant in cases],
                    probe_source=identity(Path(__file__).with_name('font_coverage_probe.cpp')),
                    driver_source=identity(Path(__file__)),
                    scope='All Unicode codepoint values including surrogates plus three out-of-range values; four coverage sweeps per face; no timing or native rendering acceptance')
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    rows = []
    for index, case in enumerate(manifest['fonts']):
        results = {}
        for label, binary in manifest['binaries'].items():
            with (output / f'{index}-{label}.stderr').open('wb') as stderr:
                result = subprocess.run([binary['path'], case['path'], case['variant']],
                                        stdout=subprocess.PIPE, stderr=stderr, check=True, timeout=180)
            results[label] = result.stdout
            (output / f'{index}-{label}.bin').write_bytes(result.stdout)
        compare(results['reference'], results['candidate'])
        bits = results['reference']
        rows.append(dict(font=case['path'], variant=case['variant'],
                         covered=sum(byte.bit_count() for byte in bits[:-OUTSIDE_UNICODE_COUNT]),
                         ascii_covered=sum(byte.bit_count() for byte in bits[:16]),
                         output_sha256=hashlib.sha256(bits).hexdigest()))
        print(f"Matched coverage: {Path(case['path']).name}, {case['variant']}", flush=True)
    for name, path in (('reference', options.reference), ('candidate', options.candidate)):
        if identity(path) != manifest['binaries'][name]:
            raise ValueError('Probe binary changed during the oracle')
    for case in manifest['fonts']:
        if identity(Path(case['path']))['sha256'] != case['sha256']:
            raise ValueError('Font bytes changed during the oracle')
    result = dict(passed=True, faces=len(rows), queries_per_probe=4 * len(rows) * (UNICODE_COUNT + OUTSIDE_UNICODE_COUNT), results=rows)
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: value for key, value in result.items() if key != 'results'}))


if __name__ == '__main__':
    main()
