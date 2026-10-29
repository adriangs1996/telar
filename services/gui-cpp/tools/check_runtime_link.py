import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import re
import struct
import subprocess

from check_peek_labels import protocol


def sha(data):
    return hashlib.sha256(data).hexdigest()


def function(source, name):
    start = source.index('fn ' + name + '(')
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def fixtures():
    cases = []
    targets = [b'', b'host', b'dev@host', b'a' * 254, b'a' * 255, b'a' * 256, b'a' * 512, ('é' * 128).encode(), ('中' * 100).encode(), ('🌍' * 100).encode(), b'a' * 255 + b'\xff', b'\xff' + b'a' * 255, b'a' * 254 + '🌍'.encode(), b'\0host']
    failures = [b'', b' \t\r\n', b'failed', b' \tfailed\r\nnext\x7f \t', bytes(range(128)), b'x' * 255, b'x' * 256, b'x' * 257, b'x' * 256 + b'\xff', b'\xff', ('é' * 200).encode(), b'x' * 255 + '🌍'.encode(), b' ' * 16384 + b'failure\n', b'long ' * 4096]
    for phase in range(5):
        for sessions in [0, 1, 4294967295]:
            for attempt in [0, 1, 5, 6, 16, 65534, 65535]:
                for setup in [False, True]:
                    for target in targets:
                        cases.append(dict(phase=phase, sessions=sessions, attempt=attempt, setup=setup, target=target, failure=failures[len(cases) % len(failures)]))
    randomizer = random.Random(0x4C494E4B)
    for _ in range(2048):
        alphabet = [b'a', b' ', b'\t', b'\r', b'\n', b'\x00', b'\x7f', b'\xff', b'\x80', 'é'.encode(), '中'.encode(), '🌍'.encode()]
        target = b''.join(randomizer.choices(alphabet, k=randomizer.randrange(600)))
        failure = b''.join(randomizer.choices(alphabet, k=randomizer.randrange(1024)))
        cases.append(dict(phase=randomizer.randrange(5), sessions=randomizer.choice([0, 1, 2, 4294967295]), attempt=randomizer.randrange(65536), setup=bool(randomizer.getrandbits(1)), target=target, failure=failure))
    return cases


def parse(data, count):
    result = []
    offset = 0
    for _ in range(count):
        row = []
        for _ in range(3):
            size = struct.unpack_from('<I', data, offset)[0]
            offset += 4
            row.append(data[offset:offset + size].hex())
            offset += size
        row.append(struct.unpack_from('<i', data, offset)[0])
        offset += 4
        result.append(row)
    assert offset == len(data)
    return result


def main():
    parser = argparse.ArgumentParser(description='Compare original RuntimeLink bounds, failure text, LinkStatus headlines and retry delay')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    names = ['src/model/connection/RuntimeLink.zig', 'src/gui/widgets/LinkStatus.zig', 'src/client/connection/runtime_link.zig']
    model, widget, flow = [(repository / name).read_text() for name in names]
    for name in names:
        (output / Path(name).name).write_bytes((repository / name).read_bytes())
    constants = '\n'.join(re.search(r'^const ' + name + r' = .*;$', flow, re.M).group() for name in ['first_retry_ms', 'longest_retry_ms', 'max_backoff_doublings'])
    start = flow.index('    const shift: u5 =', flow.index('fn scheduleRetry('))
    end = flow.index('    const deadline_ns =', start)
    retry = flow[start:end]
    header = 'const std = @import("std");\nconst OriginalRuntimeLink = @import("RuntimeLink.zig");\nconst RuntimeLink = OriginalRuntimeLink;\nconst data = struct { const RuntimeLink = OriginalRuntimeLink; };\n'
    main_body = r'''
pub fn main() !void {
    while (getchar() >= 0) {
        var link: RuntimeLink = .{};
        link.phase = @enumFromInt(try read(u8));
        link.attempt = try read(u16);
        link.sessions = try read(u32);
        link.setup_repairs = try read(u8) != 0;
        var target_storage: [65536]u8 = undefined;
        var failure_storage: [65536]u8 = undefined;
        link.name(try readText(&target_storage));
        link.fail(try readText(&failure_storage));
        try writeText(link.target());
        try writeText(link.failure() orelse "");
        var storage: [max_headline_bytes]u8 = undefined;
        try writeText(headlineText(&link, &storage));
        const client = .{ .model = .{ .runtime_link = link } };
RETRY
        const delay: i32 = @intCast(delay_ms);
        for (std.mem.asBytes(&delay)) |byte| {
            if (putchar(byte) < 0) {
                return error.WriteFailed;
            }
        }
    }
}
'''
    (output / 'probe.zig').write_text(header + constants + '\nconst max_headline_bytes = 320;\n' + function(widget, 'headlineText') + '\n' + protocol + main_body.replace('RETRY', retry))
    command = ['zig', 'build-exe', '-O', 'ReleaseFast', '-lc', str(output / 'probe.zig'), '-femit-bin=' + str(output / 'original-link')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    cases = fixtures()
    requests = bytearray()
    for case in cases:
        requests.extend(b'\0' + struct.pack('<BHIB', case['phase'], case['attempt'], case['sessions'], case['setup']))
        for key in ['target', 'failure']:
            value = case[key]
            requests.extend(struct.pack('<I', len(value)) + value)
    (output / 'requests.bin').write_bytes(requests)
    (output / 'fixtures.json').write_text(json.dumps([{**case, 'target':case['target'].hex(), 'failure':case['failure'].hex()} for case in cases], indent=2) + '\n')
    binary = options.build_dir.resolve() / 'gui-runtime-link-probe'
    results = {}
    for kind, executable in [('original', output / 'original-link'), ('cpp', binary)]:
        result = subprocess.run([str(executable)], input=requests, capture_output=True, check=True)
        (output / (kind + '.bin')).write_bytes(result.stdout)
        (output / (kind + '.stderr')).write_bytes(result.stderr)
        results[kind] = result.stdout
    left, right = [parse(results[kind], len(cases)) for kind in ['original', 'cpp']]
    differences = [dict(index=index, original=original, cpp=cpp) for index, (original, cpp) in enumerate(zip(left, right)) if original != cpp]
    (output / 'differences.json').write_text(json.dumps(differences, indent=2) + '\n')
    sources = names + ['services/gui-cpp/transport/runtime_link.hpp', 'services/gui-cpp/tools/runtime_link_probe.cpp', 'services/gui-cpp/tools/check_runtime_link.py', 'services/gui-cpp/tools/check_peek_labels.py']
    record = dict(recorded_at=datetime.now(timezone.utc).isoformat(), command=command, cases=len(cases), different_cases=len(differences), input_bytes=len(requests), input_sha256=sha(requests), output_bytes={name:len(data) for name,data in results.items()}, output_sha256={name:sha(data) for name,data in results.items()}, source_sha256={name:sha((repository / name).read_bytes()) for name in sources}, binary_sha256=sha(binary.read_bytes()), sanitizer_environment={key:os.environ.get(key) for key in ['ASAN_OPTIONS', 'UBSAN_OPTIONS', 'LSAN_OPTIONS']}, scope='Whole original RuntimeLink type, unchanged LinkStatus headlineText and exact retry-delay expressions/constants. The unchanged original body is compiled in ReleaseFast, including its observed saturated-counter headline. C++ widens the display increment without overflow. Worker scheduling, Qt integration and native rendering are qualified separately.')
    (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
    assert not differences, f'{len(differences)} runtime-link differences retained'


if __name__ == '__main__':
    main()
