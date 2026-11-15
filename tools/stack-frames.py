#!/usr/bin/env python3
"""List the large stack frames of an arm64 binary and the deepest stack each thread entry reaches.

ThinLTO decides inlining at link time, so a frame can only be measured in the linked binary.
A function's frame is what its prologue subtracts from sp. The call graph has an edge for each
direct call (bl) and each tail branch (b) to another function. Indirect calls (blr, br) are not
followed and recursion is cut, so a depth is the deepest path of direct calls, a lower bound
when a thread also calls through function pointers, virtual functions or Qt signals.

  tools/stack-frames.py BINARY                     functions with frames of 64 KiB or more
  tools/stack-frames.py BINARY --entry REGEX       worst-case depth from each matching function
  tools/stack-frames.py BINARY --entry . --min-depth 0x60000
                                                   every function whose own calls reach 384 KiB

A thread entry usually reaches its work through an indirect call (Qt's slot objects, std::function,
virtual run()), so measuring from every function, then naming the thread each deep one runs on
from the sources, is what finds a deep stack.
"""
import argparse
import functools
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
IMMEDIATE = re.compile(r'\bsub\s+sp, sp, #(0x[0-9a-f]+|\d+)(, lsl #12)?')
REGISTER = re.compile(r'\bsub\s+sp, sp, (x\d+|w\d+)')
MOVE = re.compile(r'\bmov(?:z|k)?\s+(x\d+|w\d+), #(0x[0-9a-f]+|\d+)(?:, lsl #(\d+))?')
CALL = re.compile(r'\bb(?:l)?\s+0x[0-9a-f]+ <([^>+]+)>')
LABEL = re.compile(r'^(?:[0-9a-f]+ )?<(.+)>:$')
# The stack pointer only moves in the first instructions of a prologue.
PROLOGUE_INSTRUCTIONS = 24


def llvm(tool):
    found = sorted((ROOT / '.toolchain').glob('llvm-*/bin/' + tool))
    if not found:
        raise SystemExit(f'{tool} not found under .toolchain; run tools/cpp bootstrap')
    return str(found[-1])


def parse(binary):
    """Return each function's frame in bytes and the functions it calls directly."""
    dump = subprocess.Popen([llvm('llvm-objdump'), '-d', '--no-show-raw-insn', '--no-leading-addr', binary],
                            stdout=subprocess.PIPE, text=True)
    frames = {}
    calls = {}
    name = None
    seen = 0
    registers = {}
    for line in dump.stdout:
        line = line.rstrip()
        if line.endswith('>:'):
            match = LABEL.match(line)
            name = match.group(1) if match else line
            seen = 0
            registers = {}
            frames[name] = 0
            calls[name] = set()
            continue

        if name is None:
            continue

        seen += 1
        if seen <= PROLOGUE_INSTRUCTIONS:
            found = MOVE.search(line)
            if found:
                target, value, shift = found.group(1), int(found.group(2), 0), int(found.group(3) or 0)
                registers[target] = (registers.get(target, 0) if 'movk' in line else 0) | (value << shift)

            found = IMMEDIATE.search(line)
            if found:
                value = int(found.group(1), 0)
                frames[name] += value << 12 if found.group(2) else value

            found = REGISTER.search(line)
            if found and found.group(1) in registers:
                frames[name] += registers[found.group(1)]

        found = CALL.search(line)
        if found and found.group(1) != name:
            calls[name].add(found.group(1))

    if dump.wait() != 0:
        raise SystemExit(f'llvm-objdump failed on {binary}')

    return frames, calls


def demangle(symbols):
    output = subprocess.run([llvm('llvm-cxxfilt')], input='\n'.join(symbols), capture_output=True, text=True, check=True)

    return dict(zip(symbols, output.stdout.splitlines()))


def kib(size):
    return f'{size / 1024:8.1f} KiB'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('binary')
    parser.add_argument('--threshold', type=lambda text: int(text, 0), default=64 * 1024,
                        help='smallest frame to report, in bytes (default 64 KiB)')
    parser.add_argument('--entry', help='report the deepest direct-call stack from functions matching this regex')
    parser.add_argument('--min-depth', type=lambda text: int(text, 0), default=0,
                        help='with --entry, only report stacks at least this deep, in bytes')
    args = parser.parse_args()

    frames, calls = parse(args.binary)
    names = demangle(list(frames))
    if args.entry is None:
        for symbol in sorted((symbol for symbol in frames if frames[symbol] >= args.threshold), key=lambda symbol: -frames[symbol]):
            print(kib(frames[symbol]), names[symbol])

        return

    sys.setrecursionlimit(1_000_000)
    visiting = set()

    @functools.cache
    def deepest(function):
        if function in visiting:
            return 0, ()

        visiting.add(function)
        best = (0, ())
        for callee in calls.get(function, ()):
            best = max(best, deepest(callee), key=lambda result: result[0])

        visiting.discard(function)

        return frames.get(function, 0) + best[0], (function,) + best[1]

    entry = re.compile(args.entry)
    for symbol in frames:
        if not entry.search(names[symbol]):
            continue

        total, path = deepest(symbol)
        if total < args.min_depth:
            continue

        print(kib(total), names[symbol])
        for step in path:
            if frames.get(step, 0) >= args.threshold // 4:
                print('   ', kib(frames[step]), names.get(step, step))


if __name__ == '__main__':
    main()
