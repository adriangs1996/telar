import argparse
import hashlib
import json
from pathlib import Path
import sys
from PIL import Image, ImageChops

from terminal_cell_fixture import cases, corpus_sha256, repository
import gui_tui_latency


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compare_capture(output, region):
    pairs = []
    for original in sorted(output.glob('*-splits-gui/window.png')):
        candidate = original.parent.with_name(original.parent.name + '-cpp') / original.name
        with Image.open(original) as source, Image.open(candidate) as target:
            left, top, right, bottom = region
            if source.size != target.size or not (0 <= left < right <= source.width and 0 <= top < bottom <= source.height):
                raise ValueError('The comparison region must fit both equally sized captures')
            difference = ImageChops.difference(source.convert('RGBA').crop(region), target.convert('RGBA').crop(region))
            coverage = difference.getchannel('R')
            for channel in ('G', 'B', 'A'):
                coverage = ImageChops.lighter(coverage, difference.getchannel(channel))
            pixels = (right-left)*(bottom-top)
            pairs.append(dict(original=str(original), candidate=str(candidate), original_sha256=sha(original), candidate_sha256=sha(candidate), region=region, compared_pixels=pixels, different_pixels=pixels-coverage.histogram()[0], difference_bounds=coverage.getbbox()))
    if not pairs:
        raise RuntimeError('No capture pair was available for comparison')
    (output / 'terminal-cell-comparison.json').write_text(json.dumps(pairs, indent=2)+'\n')
    if any(pair['different_pixels'] for pair in pairs):
        raise RuntimeError('The captured terminal regions have different RGBA pixels')


def main():
    parser = argparse.ArgumentParser(description='Capture both GUIs with the same styled, Unicode and ligature cells')
    parser.add_argument('zig_binary', type=Path)
    parser.add_argument('output_directory', type=Path)
    parser.add_argument('--compare-region', type=int, nargs=4, metavar=('LEFT', 'TOP', 'RIGHT', 'BOTTOM'))
    options, arguments = parser.parse_known_args()
    output = options.output_directory.resolve()
    if output.exists():
        parser.error('The output directory must be new')
    fixture_source = Path(__file__).with_name('terminal_cell_fixture.py').resolve()
    original_command = gui_tui_latency.client_command
    records = []

    def client_command(mode, binary, cpp_gui, config, fixture):
        source = Path(fixture[1])
        if source.name != 'terminal_bench_fixture.py':
            raise ValueError(f'Expected a multi-pane terminal fixture, got {source}')
        records.append(dict(mode=mode, source=str(fixture_source), sha256=sha(fixture_source), base_source=str(source), base_sha256=sha(source)))
        return original_command(mode, binary, cpp_gui, config, [fixture[0], str(fixture_source), *fixture[2:]])

    original_arguments = sys.argv
    gui_tui_latency.client_command = client_command
    sys.argv = [str(repository / 'tools/gui_tui_latency.py'), str(options.zig_binary), str(output), '--panes', '2', *arguments, '--mode', 'telar', '--cases', 'splits']
    try:
        gui_tui_latency.main()
        seen = set()
        for path in output.glob('*-splits-*/receipts/*.json'):
            receipt = json.loads(path.read_text())
            if receipt['role'] != 'background':
                continue
            data = receipt['cell_fixture']
            if data['corpus_sha256'] != corpus_sha256:
                raise RuntimeError(f'Cell fixture used a different corpus: {path}')
            if data['drawn_size'] != [receipt['cols'], receipt['rows']]:
                raise RuntimeError(f'Cell fixture changed size after drawing: {path}')
            if receipt['cols'] < data['minimum_columns'] or receipt['rows'] < data['cases']:
                raise RuntimeError(f'Cell fixture did not fit the complete corpus: {path}')
            seen.add('gui-cpp' if path.parents[1].name.endswith('-gui-cpp') else 'gui')
        if seen != {'gui', 'gui-cpp'}:
            raise RuntimeError('Both clients must capture a visible background fixture')
        if options.compare_region:
            compare_capture(output, options.compare_region)
    finally:
        gui_tui_latency.client_command = original_command
        sys.argv = original_arguments
        if output.is_dir():
            (output / 'terminal-cell-fixture.json').write_text(json.dumps(dict(cases=cases, fixtures=records, adapter_sha256=sha(Path(__file__))), ensure_ascii=False, indent=2)+'\n')


if __name__ == '__main__':
    main()
