import argparse
from collections import Counter
from decimal import Decimal, localcontext
import hashlib
import itertools
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess

from check_history_card import protocol


reference = r'''
const std = @import("std");
const io = @import("protocol.zig");
const Profiles = @import("MachineProfiles.zig");
const Profile = @import("MachineProfile.zig");
const MachineId = @import("MachineId.zig").MachineId;
const destination = @import("ssh_destination.zig");
const program = @import("remote_telar.zig");
const gpa = std.heap.page_allocator;
fn failed(err: anyerror) !void {
    try io.write(@as(u8, 0));
    try io.writeText(@errorName(err));
}
fn validate(kind: u8, text: []const u8) !void {
    switch (kind) {
        0 => _ = try MachineId.parse(text),
        1 => try Profile.validateLabel(text),
        2 => try destination.validate(text),
        3 => try Profile.validateDestination(text),
        4 => try Profile.validateColor(text),
        5 => try program.validate(text),
        else => return error.Validation,
    }
}
fn validationCase() !void {
    const kind = try io.read(u8);
    const text = try io.readText();
    defer gpa.free(text);
    validate(kind, text) catch |err| return failed(err);
    try io.write(@as(u8, 1));
    if (kind == 0) {
        var storage: [MachineId.text_bytes]u8 = undefined;
        try io.writeText((try MachineId.parse(text)).format(&storage));
    } else try io.writeText("");
}
fn writeProfiles(profiles: *const Profiles) !void {
    var storage: [Profiles.max_file_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try profiles.writeJson(&writer);
    try io.writeText(writer.buffered());
}
fn codecCase() !void {
    const text = try io.readText();
    defer gpa.free(text);
    const profiles = Profiles.parse(gpa, text) catch |err| return failed(err);
    try io.write(@as(u8, 1));
    try writeProfiles(&profiles);
}
fn readProfile() !Profile {
    const id = try io.readText();
    defer gpa.free(id);
    const label = try io.readText();
    defer gpa.free(label);
    const host = try io.readText();
    defer gpa.free(host);
    const has_color = try io.read(u8) != 0;
    const color = try io.readText();
    defer gpa.free(color);
    const enabled = try io.read(u8) != 0;
    const has_path = try io.read(u8) != 0;
    const path = try io.readText();
    defer gpa.free(path);
    return Profile.init(try MachineId.parse(id), .{
        .label = label, .destination = host,
        .color = if (has_color) color else null,
        .enabled = enabled, .telar_path = if (has_path) path else null,
    });
}
fn edit(profiles: *Profiles) !void {
    switch (try io.read(u8)) {
        0 => profiles.* = .{},
        1 => {
            const label = try io.readText();
            defer gpa.free(label);
            try profiles.probeRelabelLocal(label);
        },
        2 => try profiles.add(try readProfile()),
        3 => {
            const label = try io.readText();
            defer gpa.free(label);
            try profiles.remove(label);
        },
        4 => {
            const label = try io.readText();
            defer gpa.free(label);
            const replacement = try io.readText();
            defer gpa.free(replacement);
            try profiles.rename(label, replacement);
        },
        5 => {
            const label = try io.readText();
            defer gpa.free(label);
            try profiles.enable(label, try io.read(u8) != 0);
        },
        6 => {
            const label = try io.readText();
            defer gpa.free(label);
            const path = try io.readText();
            defer gpa.free(path);
            try profiles.placeTelar(label, path);
        },
        7 => {
            const label = try io.readText();
            defer gpa.free(label);
            const agent: Profile.LoginAgent = @enumFromInt(try io.read(u8));
            try profiles.recordLogin(label, agent, @enumFromInt(try io.read(u8)));
        },
        else => return error.Edit,
    }
}
fn editCase(profiles: *Profiles) !void {
    edit(profiles) catch |err| {
        try failed(err);
        return writeProfiles(profiles);
    };
    try io.write(@as(u8, 1));
    try io.writeText("");
    try writeProfiles(profiles);
}
pub fn main() !void {
    var profiles: Profiles = .{};
    while (true) {
        switch (io.operation()) {
            -1 => return,
            1 => try validationCase(),
            2 => try codecCase(),
            3 => try editCase(&profiles),
            else => return error.Operation,
        }
    }
}
'''


def text(value):
    encoded = value.encode() if isinstance(value, str) else value
    return struct.pack('<H', len(encoded)) + encoded


def profile(index, **fields):
    row = dict(id=f'm-{index:012x}', label=f'box{index}', destination=f'user@host{index}')
    row.update(fields)
    return row


def document(rows, **fields):
    record = dict(version=1, machines=rows)
    record.update(fields)
    return json.dumps(record, ensure_ascii=False, separators=(',', ':'))


def fixtures():
    random_source = random.Random(0x4d414348)
    values = ['', 'a', '-host', '_name', '.name', 'x' * 32, 'x' * 33, 'host\n', 'host\t', 'host\x7f', 'x' * 255, 'x' * 256,
              'm-000000000001', 'm-000000000000', 'm-ffffffffffff', 'm-FFFFFFFFFFFF', '#012aBc', 'red-3', 'é中', b'bad\x80',
              '/', '/telar', '/a/../b', '/a/..', '/a/..x', '/a/./b', '/path/with space', '/a;exit', "host'quote", 'user@alias;value']
    values.extend(''.join(random_source.choices("azAZ09-._/@;#$'\\é中 \t\n", k=random_source.randrange(280))) for _ in range(800))
    for kind, value in itertools.product(range(6), values):
        yield 'validation', b'\1' + bytes([kind]) + text(value)
    for value in ['', '{}', 'null', '[]', '{"version":1,"machines":[],"unknown":0}',
                  '{"version":1,"version":1,"machines":[]}', '{"version":1,"machines":[],"local_label":null}',
                  '{"version":1,"machines":[],"local_label":"\\ud800"}',
                  document([]), ' ' * 33000 + document([])]:
        yield 'codec', b'\2' + text(value)
    for version in [0, 1, 2, 3, -1, 65535, 65536, 1.0, 1e10, '1', '2', None, True]:
        for rows in [[], [profile(1)], [dict(id='broken', other=True)]]:
            yield 'codec', b'\2' + text(document(rows, version=version))
    for numeric in numeric_versions():
        yield 'codec', b'\2' + text('{"version":' + numeric + ',"machines":[]}')
    for numeric in numeric_text_variants():
        yield 'codec', b'\2' + text(document([], version=numeric))
    base = profile(1)
    variants = dict(id=['m-000000000000', 'm-FFFFFFFFFFFF', None, 1],
                    label=['', 'bad name', 'x' * 33, 'local', None, 1],
                    destination=['', '-option', 'host name', "host'quote", 'é中', 'x' * 256, None, 1],
                    color=['', '#012aBc', '#123', 'unknown-role', 'Upper', None, 1],
                    enabled=[False, True, None, 'true', 0, 1],
                    telar_path=['/telar', '/a/../b', '/a/..x', '/bad name', None, 1],
                    logins=[None, {}, dict(codex='done'), dict(codex=None), dict(codex=1), dict(codex='wrong'), dict(other='done')])
    for field, values in variants.items():
        for value in values:
            row = dict(base)
            row[field] = value
            yield 'codec', b'\2' + text(document([row], local_label='local'))
    for count in [0, 1, 15, 16, 17]:
        rows = [profile(index + 1) for index in range(count)]
        yield 'codec', b'\2' + text(document(rows))
    for _ in range(600):
        rows = []
        for index in range(random_source.randrange(17)):
            row = profile(index + 1, enabled=bool(random_source.randrange(2)))
            row['destination'] += random_source.choice(['', "'quote", '\\slash', 'é中'])
            if random_source.randrange(2):
                row['color'] = random_source.choice(['accent', 'other-role', '#aA90fF'])
            if random_source.randrange(2):
                row['telar_path'] = '/home/dev/.local/bin/telar'
            if random_source.randrange(2):
                row['logins'] = {agent: random_source.choice(['pending', 'done', 'failed', None]) for agent in ['claude', 'codex', 'pi', 'cursor', 'opencode']}
            rows.append(row)
        yield 'codec', b'\2' + text(document(rows, local_label='local', version=random_source.choice([1, 2])))
    for label in ['id', 'label', 'destination', 'color', 'enabled', 'telar_path', 'logins', '']:
        source = document([base]).replace('"destination":"user@host1"', '"destination":"user@host1",' + json.dumps(label) + ':null')
        yield 'codec', b'\2' + text(source)
    yield 'edit', b'\3\0'
    yield 'edit', b'\3\1' + text('local')
    for index in range(1, 19):
        yield 'edit', b'\3\2' + text(f'm-{index:012x}') + text(f'box{index}') + text(f'user@host{index}') + b'\0' + text('') + b'\1\0' + text('')
    for _ in range(1600):
        operation = random_source.choice([2, 3, 4, 5, 6, 7])
        label = random_source.choice(['local', 'missing', 'bad name', *[f'box{index}' for index in range(1, 20)]])
        value = b'\3' + bytes([operation])
        if operation == 2:
            identity = f'm-{random_source.randrange(1, 20):012x}'
            value += text(identity) + text(label) + text('host' + str(random_source.randrange(20))) + b'\0' + text('') + b'\1\0' + text('')
        elif operation == 3:
            value += text(label)
        elif operation == 4:
            value += text(label) + text(random_source.choice(['local', 'new', 'bad name', 'box1']))
        elif operation == 5:
            value += text(label) + bytes([random_source.randrange(2)])
        elif operation == 6:
            value += text(label) + text(random_source.choice(['/telar', '/bad path', '/a/../b']))
        else:
            value += text(label) + bytes([random_source.randrange(5), random_source.randrange(3)])
        yield 'edit', value


def numeric_versions():
    values = ['1.0', '1e0', '100e-2', '-0', '-0.0', '1e-5000', '1e-4930', '-1e-5000',
              '1.00000000000000000001', '0.99999999999999999999', '1e309', '0e99999999999999999999999']
    for value in values:
        yield value
        yield json.dumps(value)
    quoted = ['+1', '01', '1_0', '1__0', '1_', '_1', '1.', '.1', ' 1', '1 ', '',
              '0x1.0p0', '0x1e0', '0x.8p1', '0x1p0', '1e+0_0', '1e+0__0', 'NaN', '-Inf',
              '0x1.0000000000000000000000000001p0', '0x0.0001p-16480']
    for value in quoted:
        yield json.dumps(value)
    with localcontext() as context:
        context.prec = 200
        for integer in [1, 2, 3, 65535]:
            for exponent in [113 - (integer.bit_length() - 1), 114 - (integer.bit_length() - 1)]:
                half = Decimal(2) ** -exponent
                for multiple in ['-2', '-1.001', '-1', '-0.999', '0.999', '1', '1.001', '2']:
                    value = format(Decimal(integer) + Decimal(multiple) * half, 'f')
                    yield value
                    yield json.dumps(value)
        context.prec = 20000
        half_zero = Decimal(5) ** 16495 / (Decimal(10) ** 16495)
        smallest_step = Decimal(1) / (Decimal(10) ** 16496)
        for offset in [-1, 0, 1]:
            value = format(half_zero + offset * smallest_step, 'f')
            yield value
            yield json.dumps(value)


def numeric_text_variants():
    random_source = random.Random(0x128)
    for sign, exponent in itertools.product(['', '+', '-'], ['99999', '9' * 100, '0' * 100 + '1']):
        yield '0e' + sign + exponent
    for _ in range(4000):
        yield ''.join(random_source.choices('0xX123456789._+-eEpPabcdefABCDEF', k=random_source.randrange(60)))
    for _ in range(3000):
        coefficient = random_source.choice(['0', '1', '2', '65535', ''.join(random_source.choices('0123456789', k=random_source.randrange(1, 180)))])
        point = random_source.randrange(len(coefficient) + 1)
        exponent = random_source.choice(['0', '1', '-1', '999999999999999999999999', '-999999999999999999999999', str(random_source.randrange(-20000, 20000))])
        yield random_source.choice(['', '-', '+']) + coefficient[:point] + '.' + coefficient[point:] + random_source.choice(['e', 'E']) + exponent


def prepare(repository, output):
    names = ['MachineProfiles.zig', 'MachineProfile.zig', 'MachineProfileFields.zig', 'MachineId.zig',
             'AgentLogin.zig', 'ssh_destination.zig', 'remote_telar.zig']
    for name in names:
        shutil.copy2(repository / 'src/core' / name, output / name)
    path = output / 'MachineProfiles.zig'
    path.write_text(path.read_text() + '\npub fn probeRelabelLocal(self: *MachineProfiles, text: []const u8) !void { try self.relabelLocal(text); }\n')
    (output / 'probe.zig').write_text(reference)
    (output / 'protocol.zig').write_text(protocol)
    (output / 'facades.zig').write_text('pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };\n')
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', str(output / 'probe.zig'), '-femit-bin=' + str(output / 'original')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    return command, names


def replies(data, cases):
    offset = 0
    for kind, _ in cases:
        start = offset
        offset += 1
        for _ in range(2 if kind == 'edit' else 1):
            length, = struct.unpack_from('<H', data, offset)
            offset += 2 + length
        yield data[start:offset]
    assert offset == len(data)


def main():
    parser = argparse.ArgumentParser(description='Compare machine profile validation, JSON and edits with original Zig sources')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command, original_names = prepare(repository, output)
    cases = list(fixtures())
    payload = b''.join(value for _, value in cases)
    (output / 'input.bin').write_bytes(payload)
    binaries = dict(original=output / 'original', cpp=options.build_dir.resolve() / 'gui-machine-profiles-probe')
    outputs = {}
    for name, binary in binaries.items():
        result = subprocess.run([str(binary)], input=payload, capture_output=True, check=True)
        (output / (name + '-output.bin')).write_bytes(result.stdout)
        (output / (name + '-run.log')).write_bytes(result.stderr)
        outputs[name] = result.stdout
    if outputs['cpp'] != outputs['original']:
        mismatches = []
        for index, (expected, actual) in enumerate(zip(replies(outputs['original'], cases), replies(outputs['cpp'], cases))):
            if expected != actual:
                mismatches.append(dict(index=index, kind=cases[index][0], input=repr(cases[index][1]), original=repr(expected), cpp=repr(actual)))
        (output / 'mismatches.json').write_text(json.dumps(mismatches, indent=2) + '\n')
        raise AssertionError(f'{len(mismatches)} machine profile cases differ; evidence retained in {output}')
    sources = ['src/core/' + name for name in original_names]
    sources += ['services/gui-cpp/' + str(path.relative_to(repository / 'services/gui-cpp')) for path in sorted((repository / 'services/gui-cpp/machines').glob('*.hpp'))]
    sources += ['services/gui-cpp/tools/machine_profiles_probe.cpp', 'services/gui-cpp/tools/check_machine_profiles.py']
    sources += ['services/gui-cpp/text/' + name for name in ['binary_fraction.hpp', 'json_unsigned_integer.hpp', 'number_radix.hpp', 'radix_number.hpp']]
    result = dict(cases=len(cases), cases_by_kind=dict(Counter(kind for kind, _ in cases)),
                  input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(outputs['cpp']),
                  output_sha256=hashlib.sha256(outputs['cpp']).hexdigest(), reference_command=command,
                  binary_sha256={name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in binaries.items()},
                  source_sha256={name: hashlib.sha256((repository / name).read_bytes()).hexdigest() for name in sources},
                  scope='Original complete MachineProfiles, MachineProfile, MachineId and field validators. One wrapper exposes the unchanged private local-label setter. Compares validation errors, JSON bytes and stateful edits. Does not establish filesystem, SSH transport, machine switching, native pixels or comparative performance parity.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ['cases', 'cases_by_kind', 'output_bytes', 'output_sha256']}, indent=2))


if __name__ == '__main__':
    main()
