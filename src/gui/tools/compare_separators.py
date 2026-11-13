import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys

from PIL import Image, ImageChops

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'tools'))
from benchmark_host import HostLoadGate


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_run(binary, directory, label, options):
    command = [str(binary), '--iterations', str(options.iterations), '--warmup', str(options.warmup),
               '--blocks', str(options.blocks)]
    if label.startswith('0-'):
        command += ['--output', str(directory / (label + '.png'))]
    environment = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software')
    result = subprocess.run(command, capture_output=True, text=True, timeout=300, check=False, env=environment)
    (directory / (label + '.jsonl')).write_text(result.stdout)
    (directory / (label + '.stderr')).write_text(result.stderr)
    result.check_returncode()
    row = json.loads(result.stdout)
    expected = dict(iterations=options.iterations, warmup=options.warmup, blocks=options.blocks)
    if any(row.get(key) != value for key, value in expected.items()):
        raise ValueError(f'Inconsistent separators workload: {row}')
    if not isinstance(row.get('cpu_ns'), int) or row['cpu_ns'] <= 0:
        raise ValueError('Expected a positive CPU duration')
    return row


def compare_images(before, after, difference_path):
    with Image.open(before) as source, Image.open(after) as target:
        if source.size != target.size:
            raise ValueError('The separators captures have different dimensions')
        difference = ImageChops.difference(source.convert('RGBA'), target.convert('RGBA'))
        maximum = max(channel[1] for channel in difference.getextrema())
        if maximum:
            difference.save(difference_path)
        return dict(baseline_sha256=digest(before), candidate_sha256=digest(after), size=source.size,
                    maximum_channel_difference=maximum, difference_bounds=difference.convert('RGB').getbbox())


def main():
    parser = argparse.ArgumentParser(description='Paired CPU comparison of command separator refreshes, with the '
                                                 'separator records and the final window as the oracle')
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--iterations', type=int, default=60)
    parser.add_argument('--warmup', type=int, default=10)
    parser.add_argument('--blocks', type=int, default=20)
    parser.add_argument('--pairs', type=int, default=7)
    options = parser.parse_args()
    if not 1 <= options.pairs <= 31 or not 1 <= options.iterations <= 10000 or not 0 <= options.warmup <= 10000:
        parser.error('Expected 1..31 pairs, 1..10000 iterations and 0..10000 warmup refreshes')
    directory = options.directory.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    host = HostLoadGate(directory / 'host-load.json')
    host.checkpoint('before-series')
    binaries = dict(baseline=options.baseline.resolve(), candidate=options.candidate.resolve())
    manifest = dict(binaries={name: dict(path=str(path), sha256=digest(path)) for name, path in binaries.items()},
                    command_line=sys.argv, uptime=subprocess.check_output(['uptime'], text=True).strip())
    (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    pairs = []
    for index in range(options.pairs):
        order = ['baseline', 'candidate'] if index % 2 == 0 else ['candidate', 'baseline']
        pair = {}
        for name in order:
            with host.run(f'{index}-{name}'):
                pair[name] = read_run(binaries[name], directory, f'{index}-{name}', options)
        pairs.append(pair)
        print('Completed pair', index + 1, flush=True)

    host.finish()
    records = {pair[name]['separators_sha256'] for pair in pairs for name in pair}
    if len(records) != 1:
        raise ValueError(f'The separator records differ between runs: {sorted(records)}')
    before = [pair['baseline']['cpu_ns'] / options.iterations for pair in pairs]
    after = [pair['candidate']['cpu_ns'] / options.iterations for pair in pairs]
    pixels = compare_images(directory / '0-baseline.png', directory / '0-candidate.png', directory / 'difference.png')
    result = dict(manifest=manifest, baseline_median_ns=statistics.median(before),
                  candidate_median_ns=statistics.median(after),
                  median_paired_ratio=statistics.median(right / left for left, right in zip(before, after)),
                  wins=sum(right < left for left, right in zip(before, after)), pairs=pairs, pixels=pixels,
                  scope='GUI-thread CPU from sending a block update that moves every separator a row until the '
                        'separators show it: the client session, the terminal item and the QML separators. '
                        'Rendering after the update is excluded; the software Quick backend draws the final oracle.')
    for name, path in binaries.items():
        if digest(path) != manifest['binaries'][name]['sha256']:
            raise ValueError(f'The {name} binary changed during the comparison')
    (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f"{result['baseline_median_ns'] / 1e6:.3f} -> {result['candidate_median_ns'] / 1e6:.3f} ms/refresh; "
          f"wins {result['wins']}/{options.pairs}; maximum oracle pixel delta {pixels['maximum_channel_difference']}")
    if not all(math.isfinite(value) for value in before + after):
        raise ValueError('Expected finite durations')
    if pixels['maximum_channel_difference']:
        raise ValueError('Rendered separators differ; inspect the image oracle before accepting performance results')


if __name__ == '__main__':
    main()
