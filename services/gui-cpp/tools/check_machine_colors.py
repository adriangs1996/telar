import argparse
from datetime import datetime, timezone
import hashlib
import itertools
import json
from pathlib import Path
import random
import re
import shutil
import subprocess


probe = r'''
const colors = @import("color_name.zig");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn byte() !u8 {
    const value = getchar();
    if (value < 0) return error.TruncatedInput;
    return @intCast(value);
}
pub fn main() !void {
    while (getchar() >= 0) {
        var storage: [255]u8 = undefined;
        const size = try byte();
        for (storage[0..size]) |*value| value.* = try byte();
        var output: [4]u8 = @splat(0);
        if (colors.parse(storage[0..size])) |value| {
            switch (value) {
                .palette => |role| { output[0] = 3; output[1] = @intFromEnum(role); },
                .value => |literal| { output[0] = if (literal.kind == .default) 1 else 2; @memcpy(output[1..], &literal.value); },
            }
        }
        for (output) |value| { if (putchar(value) < 0) return error.WriteFailed; }
    }
}
'''
cellgrid = '''pub const Color = struct {
    kind: enum { default, rgb, indexed } = .default,
    value: [3]u8 = @splat(0),
    pub const default: @This() = .{};
    pub fn rgb(channels: [3]u8) @This() { return .{ .kind = .rgb, .value = channels }; }
};
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fixtures(roles):
    cases = set()
    for role in [*roles, 'default']:
        positions = [index for index, letter in enumerate(role) if letter.isalpha()]
        for casing in itertools.product([False, True], repeat=len(positions)):
            value = list(role)
            for index, upper in zip(positions, casing):
                if upper:
                    value[index] = value[index].upper()
            value = ''.join(value)
            cases.update([value.encode(), value.replace('_', '-').encode()])
        for invalid in [role + ' ', ' ' + role, role + '\0', role + 'x', role.replace('_', '')]:
            cases.add(invalid.encode())
    for value in range(4096):
        cases.add(f'#{value:06x}'.encode())
        cases.add(f'#{0xffffff - value:06X}'.encode())
    for value in ['', '#', '#0000000', '#12345', '#-00000', '#-00001', '#+FFFFF', '#ff__ff', '#_fffff', '#fffff_', '#0x00ff', '#000_00', '#0__000', '#ééé', 'réD', '默认']:
        cases.add(value.encode())
    alphabet = b'0123456789abcdefABCDEF_+-xX? \0'
    for first in range(6):
        for second in range(first + 1, 6):
            for left in alphabet:
                for right in alphabet:
                    value = bytearray(b'#000000')
                    value[first + 1] = left
                    value[second + 1] = right
                    cases.add(bytes(value))
    randomizer = random.Random(0x3017)
    for _ in range(12000):
        cases.add(b'#' + bytes(randomizer.choices(alphabet, k=6)))
        cases.add(bytes(randomizer.randrange(256) for _ in range(randomizer.randrange(256))))
    return sorted(cases)


def main():
    parser = argparse.ArgumentParser(description='Compare written machine colors with the unchanged original Zig parser')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    originals = ['src/model/bars/color_name.zig', 'src/model/bars/model.zig']
    source = (repository / originals[1]).read_text()
    palette = re.search(r'pub const PaletteColor = enum \{.*?\n\};', source, re.S).group()
    color = re.search(r'pub const Color = union\(enum\) \{.*?\n\};', source, re.S).group()
    roles = re.findall(r'^\s+(\w+),$', palette, re.M)
    shutil.copy2(repository / originals[0], output / 'color_name.zig')
    (output / 'model.zig').write_text('const cellgrid = @import("cellgrid.zig");\n' + palette + '\n' + color + '\n')
    (output / 'cellgrid.zig').write_text(cellgrid)
    (output / 'probe.zig').write_text(probe)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', str(output / 'probe.zig'), '-femit-bin=' + str(output / 'original-colors')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    cases = fixtures(roles)
    requests = b''.join(b'\0' + bytes([len(value)]) + value for value in cases)
    (output / 'requests.bin').write_bytes(requests)
    (output / 'cases.json').write_text(json.dumps([value.hex() for value in cases]) + '\n')
    results = {}
    for kind, binary in [('original', output / 'original-colors'), ('cpp', options.build_dir.resolve() / 'gui-machine-color-probe')]:
        result = subprocess.run([str(binary)], input=requests, capture_output=True, check=True)
        (output / (kind + '.bin')).write_bytes(result.stdout)
        (output / (kind + '.stderr')).write_bytes(result.stderr)
        assert len(result.stdout) == len(cases) * 4
        results[kind] = result.stdout
    differences = [index for index in range(len(cases)) if results['original'][4*index:4*index+4] != results['cpp'][4*index:4*index+4]]
    result = dict(recorded_at=datetime.now(timezone.utc).isoformat(), cases=len(cases), bytes=len(results['original']), differences=len(differences), input_sha256=sha(requests), output_sha256={kind:sha(value) for kind,value in results.items()}, source_sha256={name:sha((repository/name).read_bytes()) for name in [*originals, 'services/gui-cpp/core/color_name.hpp', 'services/gui-cpp/tools/machine_color_probe.cpp', str(Path(__file__).relative_to(repository))]}, command=command, scope='Unchanged original written-color parser and extracted original palette/color type declarations. The cell-color storage facade preserves parser constructors and values. This does not establish native ink or visual acceptance.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    for index in differences[:20]:
        print(cases[index], results['original'][4*index:4*index+4].hex(), results['cpp'][4*index:4*index+4].hex())
    print(json.dumps(result))
    assert not differences


if __name__ == '__main__':
    main()
