#!/usr/bin/env python3
"""Compare two GUI binaries at matching marker-pixel GPU completion on macOS."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from gui_tui_latency import WARMUP, measure, summarize


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--viewport', type=int, nargs=2, default=[1000, 700])
    options = parser.parse_args()
    if not 1 <= options.samples <= 400 or not 1 <= options.rounds <= 10:
        parser.error('samples must be 1..400 and rounds 1..10')
    if any(value < 1 or value > 8192 for value in options.viewport):
        parser.error('viewport dimensions must be 1..8192')
    options.input_method = 'text'
    options.vsync = 'true'
    directory = options.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    library = directory / 'probe.dylib'
    subprocess.run(['clang', '-dynamiclib', '-O2', '-fobjc-arc', '-framework', 'AppKit',
                    '-framework', 'QuartzCore', '-framework', 'Metal',
                    str(Path(__file__).with_name('gui_tui_latency.m')), '-o', str(library)], check=True)
    config = directory / 'config.lua'
    config.write_text("return { api_version = 2, client = { sidebar = { visible = true, renderer = 'cells' } }, "
                      "gui = { cursor = { blink = false } } }\n")
    binaries = dict(baseline=options.baseline.resolve(), candidate=options.candidate.resolve())
    report = dict(viewport=options.viewport, warmup=WARMUP,
                  endpoint='committed text to matching marker-pixel GPU completion',
                  binaries={name: dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                            for name, path in binaries.items()}, runs=[])
    for index in range(options.rounds):
        order = ['baseline', 'candidate'] if index % 2 == 0 else ['candidate', 'baseline']
        for name in order:
            result = measure('gui', directory / f'{index}-{name}',
                             (binaries[name], None, library, config, options))
            result['variant'] = name
            report['runs'].append(result)
    report['aggregate'] = {
        name: summarize([value for run in report['runs'] if run['variant'] == name
                         for value in run['gpu_ms'][WARMUP:]]) for name in binaries
    }
    (directory / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['aggregate'], indent=2))


if __name__ == '__main__':
    main()
