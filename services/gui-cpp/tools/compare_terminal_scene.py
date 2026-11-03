import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess

from PIL import Image, ImageChops


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_run(binary, directory, label, options):
    command = [str(binary), '--iterations', str(options.iterations), '--warmup', str(options.warmup),
               '--font', options.font, '--scale', str(options.scale)]
    if options.no_thicken:
        command.append('--no-thicken')
    if options.snapshot_workload != 'full':
        command += ['--snapshot-workload', options.snapshot_workload]
    if label.startswith('0-'):
        command += ['--output', str(directory / (label + '.png'))]
    result = subprocess.run(command, capture_output=True, text=True, timeout=90, check=False)
    (directory / (label + '.jsonl')).write_text(result.stdout)
    (directory / (label + '.stderr')).write_text(result.stderr)
    result.check_returncode()
    row = json.loads(result.stdout)
    expected = dict(iterations=options.iterations, warmup=options.warmup, font=options.font,
                    scale=options.scale, thicken=not options.no_thicken, columns=256, rows=52)
    if any(row.get(key) != value for key, value in expected.items()):
        raise ValueError(f'Inconsistent terminal scene workload: {row}')
    if row.get('snapshot_workload', 'full') != options.snapshot_workload:
        raise ValueError('Inconsistent snapshot workload')
    duration = row.get(options.metric)
    if not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration <= 0:
        raise ValueError('Expected a finite positive terminal scene duration')
    if options.metric == 'apply_and_paint_ns':
        application = row.get('apply_ns')
        paint = row.get('elapsed_ns')
        if (not all(isinstance(value, (int, float)) and math.isfinite(value) and value > 0
                    for value in (application, paint)) or duration != application + paint):
            raise ValueError('Application and painting must account for the complete measured duration')

    return row


def compare_images(before, after, difference_path):
    with Image.open(before) as source, Image.open(after) as target:
        if source.size != target.size:
            raise ValueError('The terminal scene captures have different dimensions')
        difference = ImageChops.difference(source.convert('RGBA'), target.convert('RGBA'))
        maximum = max(channel[1] for channel in difference.getextrema())
        result = dict(baseline_sha256=digest(before), candidate_sha256=digest(after),
                      size=source.size, maximum_channel_difference=maximum,
                      difference_bounds=difference.convert('RGB').getbbox())
        if maximum:
            difference.save(difference_path)

    return result


def main():
    parser = argparse.ArgumentParser(description='Paired terminal text scene CPU comparison with final rendered-pixel verification')
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--font', default='JetBrains Mono')
    parser.add_argument('--scale', type=int, choices=[1, 2], default=2)
    parser.add_argument('--iterations', type=int, default=12)
    parser.add_argument('--warmup', type=int, default=3)
    parser.add_argument('--pairs', type=int, default=7)
    parser.add_argument('--no-thicken', action='store_true')
    parser.add_argument('--snapshot-workload', choices=['full', 'sparse', 'retained'], default='full')
    parser.add_argument('--metric', choices=['elapsed_ns', 'apply_and_paint_ns'], default='elapsed_ns',
                        help='Scene synchronization alone, or decoded-frame application plus scene synchronization')
    parser.add_argument('--reference-image', type=Path, help='Independent visual oracle when the baseline has a known rendering defect')
    options = parser.parse_args()
    if not 1 <= options.pairs <= 31 or not 1 <= options.iterations <= 1000 or not 0 <= options.warmup <= 1000:
        parser.error('Expected 1..31 pairs, 1..1000 iterations and 0..1000 warmup repaints')
    directory = options.directory.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    binaries = dict(baseline=options.baseline.resolve(), candidate=options.candidate.resolve())
    manifest = dict(binaries={name: dict(path=str(path), sha256=digest(path)) for name, path in binaries.items()},
                    command_line=os.sys.argv, uptime=subprocess.check_output(['uptime'], text=True).strip(),
                    environment={key: value for key, value in os.environ.items() if key.startswith(('QT_', 'QSG_'))})
    (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    pairs = []
    for index in range(options.pairs):
        order = ['baseline', 'candidate'] if index % 2 == 0 else ['candidate', 'baseline']
        pair = {name: read_run(binaries[name], directory, f'{index}-{name}', options) for name in order}
        pairs.append(pair)
        print('Completed pair', index + 1, flush=True)

    before = [pair['baseline'][options.metric] / options.iterations for pair in pairs]
    after = [pair['candidate'][options.metric] / options.iterations for pair in pairs]
    pixels = compare_images(directory / '0-baseline.png', directory / '0-candidate.png', directory / 'difference.png')
    reference = compare_images(options.reference_image, directory / '0-candidate.png', directory / 'reference-difference.png') if options.reference_image else pixels
    result = dict(manifest=manifest, baseline_median_ns=statistics.median(before),
                  candidate_median_ns=statistics.median(after),
                  median_paired_ratio=statistics.median(right / left for left, right in zip(before, after)),
                  wins=sum(right < left for left, right in zip(before, after)), pairs=pairs,
                  pixels=pixels, visual_oracle=reference,
                  reference_image=str(options.reference_image.resolve()) if options.reference_image else None,
                  metric=options.metric, snapshot_workload=options.snapshot_workload,
                  scope=('CPU decoded-frame application plus production TerminalScene synchronization; fixture encoding is excluded. '
                         if options.metric == 'apply_and_paint_ns' else
                         'CPU production TerminalScene synchronization; frame preparation and decoding are excluded. ')
                        + 'The grid has 256x52 ASCII cells and warm glyph caches. Final native-window captures verify visible pixels. This does not measure full application FPS, runtime throughput or native drawable cadence.')
    for name, path in binaries.items():
        if digest(path) != manifest['binaries'][name]['sha256']:
            raise ValueError(f'The {name} binary changed during the comparison')
    (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f"{result['baseline_median_ns'] / 1e6:.3f} -> {result['candidate_median_ns'] / 1e6:.3f} ms/iteration; wins {result['wins']}/{options.pairs}; maximum oracle pixel delta {reference['maximum_channel_difference']}")
    if reference['maximum_channel_difference']:
        raise ValueError('Rendered terminal pixels differ; inspect the image oracle before accepting performance results')


if __name__ == '__main__':
    main()
