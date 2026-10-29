#!/usr/bin/env python3
"""Compare ARM64 generated constants and linked instructions separately.

Linked PAGE/PAGEOFF relocations are normalized only after checking the generated
instruction operands and recursively resolved constant data. Arithmetic
immediates, registers, internal branch offsets and imported call names remain.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


LOCAL_DATA = re.compile(r'\b(?:l_\.(?:str|constant)(?:\.\d+)?|lCPI\d+_\d+|[lL]JTI\d+_\d+)\b')


def uncomment(line):
    quoted = False
    escaped = False
    for index, character in enumerate(line):
        if escaped:
            escaped = False
            continue
        if character == '\\':
            escaped = True
            continue
        if character == '"':
            quoted = not quoted
        if character == ';' and not quoted:
            return line[:index].rstrip()
    return line.rstrip()


def generated_functions(path):
    lines = path.read_text().splitlines()
    data = {}
    current = None
    for line in lines:
        match = re.match(r'^([\w.$]+):', line)
        if match:
            current = match[1]
            data[current] = []
        elif current and re.match(r'^\t\.(?:asciz|ascii|quad|long|short|byte|zero|space)\b', line):
            data[current].append(uncomment(line).strip())
        elif line.startswith(('\t.section', '\t.globl')):
            current = None

    def resolve(name, seen=frozenset()):
        if name in seen:
            return '@SELF'
        if name not in data or not data[name]:
            raise ValueError('Unresolved constant data: ' + name)
        value = '\n'.join(data[name])
        value = re.sub(r'\bLBB\d+_(\d+)', r'LBB_\1', value)
        value = LOCAL_DATA.sub(lambda match: resolve(match[0], seen | {name}), value)
        return '@DATA_' + hashlib.sha256(value.encode()).hexdigest()

    result = {}
    name = None
    for raw in lines:
        if re.match(r'^_[\w.$]+:', raw):
            name = raw.split(':', 1)[0]
            body = []
        if name and re.match(r'^\t[a-z][a-z0-9.]*\s', raw):
            line = re.sub(r'\bLBB\d+_(\d+)', r'LBB_\1', uncomment(raw).strip())
            body.append(LOCAL_DATA.sub(lambda match: resolve(match[0]), line))
        if name and '.cfi_endproc' in raw:
            result[name] = body
            name = None
    return result


def linked_functions(path, objdump):
    indirect = subprocess.check_output([objdump, '--macho', '--indirect-symbols', str(path)], text=True)
    stubs = {int(match[1], 16): match[2] for line in indirect.splitlines()
             if (match := re.match(r'0x([a-f0-9]+)\s+\d+\s+(\S+)', line))}
    assembly = subprocess.check_output([objdump, '-d', '--no-show-raw-insn', str(path)], text=True)
    result = {}
    non_writers = {'str', 'stp', 'stur', 'strb', 'strh', 'cmp', 'cmn', 'tst', 'ccmp', 'ccmn', 'b', 'bl', 'cbz', 'cbnz', 'tbz', 'tbnz'}
    for block in re.split(r'(?=^[0-9a-f]+ <)', assembly, flags=re.M):
        header = re.match(r'[0-9a-f]+ <([^>]+)>:', block)
        if not header:
            continue
        body = []
        pages = set()
        for line in block.splitlines()[1:]:
            match = re.match(r'\s*[a-f0-9]+:\s*(.+)', line)
            if not match:
                continue
            instruction = uncomment(match[1]).strip()
            operation = instruction.split()[0]
            if operation == 'adrp':
                register = re.search(r'adrp\s+(x\d+),', instruction)[1]
                pages.add(register)
                body.append(re.sub(r'0x[a-f0-9]+(?: <[^>]+>)?', '@PAGE', instruction))
                continue
            if operation == 'add':
                address = re.match(r'add\s+(x\d+),\s*(x\d+),\s*#0x[a-f0-9]+$', instruction)
                if address and address[2] in pages:
                    instruction = re.sub(r'#0x[a-f0-9]+$', '@PAGEOFF', instruction)
            for register in pages:
                instruction = re.sub(r'(\[' + register + r',\s*)#0x[a-f0-9]+(\])', r'\1@PAGEOFF\2', instruction)
            instruction = re.sub(r'0x([a-f0-9]+) <([^>]+)>', lambda match: '<' + stubs.get(int(match[1], 16), match[2]) + '>', instruction)
            if operation not in non_writers and not operation.startswith('b.'):
                destination = re.match(r'\w+(?:\.\w+)?\s+[xw](\d+)', instruction)
                if destination:
                    pages.discard('x' + destination[1])
            if operation == 'bl':
                pages.difference_update('x' + str(index) for index in range(19))
            body.append(instruction)
        result[header[1]] = body
    return result


def digest(lines):
    return hashlib.sha256('\n'.join(lines).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline-assembly', type=Path, required=True)
    parser.add_argument('--candidate-assembly', type=Path, required=True)
    parser.add_argument('--baseline-binary', type=Path, required=True)
    parser.add_argument('--candidate-binary', type=Path, required=True)
    parser.add_argument('--objdump', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    generated = [generated_functions(path) for path in [args.baseline_assembly, args.candidate_assembly]]
    linked = [linked_functions(path, args.objdump) for path in [args.baseline_binary, args.candidate_binary]]
    selected = [name for name in generated[0] if any(token in name for token in
                ['6Parser', 'GraphicsQueries', 'decodeGraphicsPayload', 'GraphicsQuery5parse', 'benchmarkComponent'])
                or ('6Engine' in name and ('4feed' in name or '8complete' in name))]
    if not selected:
        raise ValueError('No expected graphics path functions found')
    checks = {}
    for name in selected:
        checks[name] = {'generated_equal': generated[0][name] == generated[1].get(name),
                        'linked_equal': linked[0].get(name) == linked[1].get(name) and name in linked[0],
                        'generated_sha256': [digest(side.get(name, [])) for side in generated],
                        'linked_sha256': [digest(side.get(name, [])) for side in linked]}
    report = {'command': sys.argv, 'selected_graphics_functions': checks,
              'all_selected_equal': all(row['generated_equal'] and row['linked_equal'] for row in checks.values()),
              'generated_function_count': [len(side) for side in generated],
              'changed_generated_functions': [name for name in generated[0] if generated[0][name] != generated[1].get(name)],
              'normalization': __doc__, 'harness_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'inputs': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in
                         [args.baseline_assembly, args.candidate_assembly, args.baseline_binary, args.candidate_binary]}}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'selected': len(checks), 'equal': report['all_selected_equal'],
                      'changed_generated_functions': report['changed_generated_functions']}))
    return not report['all_selected_equal']


if __name__ == '__main__':
    sys.exit(main())
