"""Compare code while normalizing branch and ADRP-derived relocation operands.

Ordinary instruction immediates remain intact. This compares instructions, not
relocated payload bytes. Use placement.py for the additional C constant checks.
Usage: python3 normalize-instructions.py SCRATCH
"""
from pathlib import Path
import difflib
import json
import re
import subprocess
import sys

root = Path(sys.argv[1])
symbols = [
    'main.execute', 'damage.collectSpans__anon_20706',
    'SharedFrameContext.publish', 'InboxContext.handle',
    'config.Generation.invokeCallback', 'lua_pcallk', 'luaV_execute',
    'ClientEventContext.finishEvent', 'workspace.WorkspaceLayout.focusDirection',
    'main.timed__anon_62714', 'main.timed__anon_62765', 'main.timed__anon_62828',
]


def normalize(lines):
    result = []
    pages = {}
    for line in lines:
        match = re.match(r'[0-9a-f]+:\s+(.*)', line)
        if not match:
            continue
        instruction = match[1]
        adrp = re.match(r'adrp\s+(x\d+), (0x[0-9a-f]+)', instruction)
        if adrp:
            pages[adrp[1]] = adrp[2]
            instruction = f'adrp {adrp[1]}, RELOC_PAGE'
        else:
            operand = re.match(r'(add|ldr\w*)\s+[^,]+, (?:\[)?(x\d+), #(0x[0-9a-f]+)', instruction)
            if operand and operand[2] in pages:
                pages.pop(operand[2])
                instruction = instruction.replace(operand[3], 'RELOC_OFFSET')
            written = re.match(r'\w+\s+(x\d+),', instruction)
            if written:
                pages.pop(written[1], None)
        instruction = re.sub(r'0x[0-9a-f]+ <([^>]+)>',
            lambda m: '<' + re.sub(r'\+0x[0-9a-f]+', '', m[1]) + '>', instruction)
        instruction = re.sub(r'__anon_\d+', '__anon', instruction)
        result.append(instruction)
    return '\n'.join(result) + '\n'


result = {}
for symbol in symbols:
    outputs = []
    for side in ['A', 'F']:
        raw = subprocess.check_output([
            'objdump', '-d', '--no-show-raw-insn',
            '--disassemble-symbols=_' + symbol,
            str(root / side / 'bin/telar-benchmarks'),
        ], text=True)
        assert f'<_{symbol}>:' in raw, symbol
        (root / f'{side}-{symbol}.s').write_text(raw)
        normalized = normalize(raw.splitlines())
        outputs.append(normalized)
        (root / f'{side}-{symbol}.instructions.s').write_text(normalized)
    diff = ''.join(difflib.unified_diff(outputs[0].splitlines(True), outputs[1].splitlines(True)))
    (root / f'F-{symbol}.instructions.diff').write_text(diff)
    result[symbol] = dict(identical=outputs[0] == outputs[1], diff_lines=len(diff.splitlines()))
(root / 'F-instruction-placement.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
