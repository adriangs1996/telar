#!/usr/bin/env python3
"""Keep optimized disassembly and symbol provenance; this does not count cache misses."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

SYMBOLS = ('_render.Scene.prepare', '_widgets.frame_widget.Widget.draw', '_GuiClient.draw', '_workspace.MultiplexerModel.findConst',
           '_workspace.TabsModel.findPane', '_widgets.ThreadTranscript.draw', '_ui.Cell.eqlPublic', '_runtime.application.event_dispatcher.pane.pane_pipeline.ingestPane')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    symbols = subprocess.check_output(['xcrun', 'llvm-objdump', '--macho', '--syms', str(args.binary)], text=True)
    (args.output / 'symbols.txt').write_text(symbols)
    entries = []
    for symbol in SYMBOLS:
        present = any(row.split()[-1:] == [symbol] for row in symbols.splitlines())
        entry = dict(symbol=symbol, present=present)
        if present:
            path = args.output / (symbol[1:] + '.asm')
            command = ['xcrun', 'llvm-objdump', '--macho', '--disassemble', '--dis-symname', symbol, '-g', str(args.binary)]
            with path.open('w') as output:
                subprocess.run(command, stdout=output, check=True)
            entry.update(file=path.name, sha256=hashlib.sha256(path.read_bytes()).hexdigest(), command=command)
        else:
            entry['interpretation'] = 'No standalone symbol; inspect optimized callers. Do not force noinline.'
        entries.append(entry)
    profile_symbols = [row for row in symbols.splitlines() if any(name in row for name in ('_profiling.', '_profile_store', '_ProfileStore.'))]
    manifest = dict(binary=str(args.binary.resolve()), sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                    symbols=entries, profiling_symbols=profile_symbols,
                    limitation='Symbol absence and representative code inspection do not establish hardware cache behavior.')
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
