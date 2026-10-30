#!/usr/bin/env python3
"""Negative controls for constant and arithmetic normalization, without builds."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile
from compare_control_arm_codegen import generated_functions


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--scratch', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    original = args.baseline.read_text()
    baseline = generated_functions(args.baseline)
    function = next(name for name in baseline if '6Parser' in name and '11startEscape' in name)
    label = re.search(r'^l_switch\.table\.[\w.$]*11startEscapeEh\.\d+(?=:)', original, re.M)[0]
    with tempfile.TemporaryDirectory(prefix='codegen-negative-', dir=args.scratch) as directory:
        changed = Path(directory) / 'changed.s'
        changed.write_text(original.replace(label, label + '.renamed'))
        assert generated_functions(changed) == baseline
        start = original.index(label + ':')
        tail = original[start:]
        byte = re.search(r'(?m)^\t\.byte\t(\d+)', tail)
        assert byte
        mutation = tail[:byte.start(1)] + str(int(byte[1]) ^ 1) + tail[byte.end(1):]
        changed.write_text(original[:start] + mutation)
        assert generated_functions(changed)[function] != baseline[function]
        candidate = args.candidate.read_text()
        functions = generated_functions(args.candidate)
        cursor = next(name for name in functions if '12cursorReport' in name)
        start = candidate.index(cursor + ':')
        end = candidate.index('.cfi_endproc', start)
        body = candidate[start:end]
        instruction = '\tadd\tw1, w8, #1'
        assert instruction in body
        changed.write_text(candidate[:start] + body.replace(instruction, '\tadd\tw1, w8, #2', 1) + candidate[end:])
        assert generated_functions(changed)[cursor] != functions[cursor]
        aggregate = ('_probe:\n\tadrp\tx0, l_constinit.1@PAGE\n\tret\n\t.cfi_endproc\n'
                     'l_constinit.1:\n\t.quad\tl_.str.1\n\t.quad\t3\n'
                     'l_.str.1:\n\t.asciz\t"git"\n')
        changed.write_text(aggregate)
        original_aggregate = generated_functions(changed)
        changed.write_text(aggregate.replace('l_constinit.1', 'l_constinit.27').replace('l_.str.1', 'l_.str.28'))
        assert generated_functions(changed) == original_aggregate
        changed.write_text(aggregate.replace('"git"', '"got"'))
        assert generated_functions(changed) != original_aggregate
        changed.write_text(aggregate.replace('\t.quad\t3', '\t.quad\t4'))
        assert generated_functions(changed) != original_aggregate
    report = {'command': sys.argv, 'scope': __doc__,
              'label_only_renumbering_preserves_all_functions': True,
              'switch_table_byte_change_detected': True,
              'cursor_arithmetic_immediate_change_detected': True,
              'aggregate_label_renumbering_preserves_function': True,
              'aggregate_referenced_string_change_detected': True,
              'aggregate_numeric_member_change_detected': True,
              'hashes': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in
                         [Path(__file__), Path(__file__).with_name('compare_control_arm_codegen.py'), args.baseline, args.candidate]}}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('Six codegen normalization controls passed')


if __name__ == '__main__':
    main()
