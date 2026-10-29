import argparse
from collections import Counter
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess

from check_history_card import protocol
from check_machine_profiles import text


reference = r'''
const std = @import("std");
const io = @import("protocol.zig");
const Discovery = @import("machines/Discovery.zig");
const remote = @import("machines/remote.zig");
const policy = @import("machines/machine_connection.zig");
const gpa = std.heap.page_allocator;
fn failed(err: anyerror) !void {
    try io.write(@as(u8, 0));
    try io.writeText(@errorName(err));
}
fn discoveryCase() !void {
    const input = try io.readText();
    defer gpa.free(input);
    const found = Discovery.parse(input) catch |err| return failed(err);
    const defaults = found.launchDefaults();
    try io.write(@as(u8, 1));
    try io.writeText(defaults.cwd);
    try io.writeText(defaults.shell);
    try io.writeText(found.endpoint());
    try io.writeText(&found.schema);
    try io.write(@as(u8, @intFromBool(found.compatible())));
}
fn commandCase() !void {
    const discovery = try io.read(u8) != 0;
    const has_program = try io.read(u8) != 0;
    const program = try io.readText();
    defer gpa.free(program);
    var storage: [4096]u8 = undefined;
    const command = remote.remoteCommand(&storage, if (has_program) program else null,
        if (discovery) "/bin/sh -c 'printf \"%s\\n\" \"$HOME\" \"${SHELL:-/bin/sh}\"; exec " else "exec ",
        if (discovery) " server endpoint'" else " server bridge") catch |err| return failed(err);
    try io.write(@as(u8, 1));
    try io.writeText(command);
}
fn failureCase() !void {
    const exited = try io.read(u8) != 0;
    const status = try io.read(u8);
    const input = try io.readText();
    defer gpa.free(input);
    const term: std.process.Child.Term = if (exited) .{ .exited = status } else .{ .signal = .KILL };
    try io.writeText(@errorName(remote.sshFailure(term, input)));
}
fn policyCase() !void {
    const name = try io.readText();
    defer gpa.free(name);
    const errors = .{
        error.InvalidMachineId, error.InvalidMachineLabel, error.InvalidRemoteDestination,
        error.InvalidMachineColor, error.InvalidRemoteTelarPath, error.InvalidMachineProfiles,
        error.IncompatibleMachineProfiles, error.TooManyMachines, error.DuplicateMachineId,
        error.DuplicateMachineLabel, error.DuplicateMachineDestination, error.UnknownMachine,
        error.RemoteDiscoveryUnreadable, error.SshHostKeyRejected, error.SshAuthenticationFailed,
        error.RemoteTelarMissing, error.RemoteTelarIncompatible, error.RemoteRuntimeIncompatible,
        error.RemoteEndpointUnavailable, error.IncompatibleSchema, error.RuntimeAlreadyRunning,
        error.InvalidRuntimeDirectory, error.UnexpectedError,
    };
    inline for (errors) |err| {
        if (std.mem.eql(u8, name, @errorName(err))) {
            try io.write(@as(u8, @intFromBool(policy.permanent(err))));
            try io.write(@as(u8, @intFromBool(policy.setupRepairs(err))));
            return;
        }
    }
    return error.UnknownPolicy;
}
pub fn main() !void {
    while (true) {
        switch (io.operation()) {
            -1 => return,
            1 => try discoveryCase(),
            2 => try commandCase(),
            3 => try failureCase(),
            4 => try policyCase(),
            else => return error.Operation,
        }
    }
}
'''


def fixtures(path_limit, schema):
    random_source = random.Random(0x535348)
    base = [b'/home/dev', b'/bin/sh', b'/run/telar.sock', schema]
    yield 'discovery', b'\1' + text(b'\n'.join(base) + b'\n')
    for index in range(4):
        values = [b'', b'/', b'relative', b'/a b', b'/a:b', b'/a\0b', b'/a\tb', b'/a\rb', b'/a\x7fb',
                  b'/invalid\x80', b'/' + b'a' * (path_limit - 1), b'/' + b'a' * path_limit,
                  b'/' + b'a' * (path_limit + 1), b'12345678', b'1234567_', b'ABCDEFGH', schema]
        values.extend(bytes(random_source.randrange(256) for _ in range(random_source.randrange(40))) for _ in range(400))
        for value, suffix in itertools.product(values, [b'', b'\n', b'\n\n', b'\nextra', b'\r\n']):
            lines = list(base)
            lines[index] = value
            yield 'discovery', b'\1' + text(b'\n'.join(lines) + suffix)
    for length in [0, 1, 3 * (path_limit + 1) + len(schema) + 1, 3 * (path_limit + 1) + len(schema) + 2]:
        yield 'discovery', b'\1' + text(b'\n'.join(base) + b'\n' * length)
    paths = [None, '', '/telar', '/opt/bin/telar', 'telar', '/', '/a/', '/a/../b', '/a/..', '/a/..x',
             '/a;exit', '/a b', '/a\'b', '/a\nb', '/a\0b', '/a\\b', '/a/./b', '/' + 'x' * 254, '/' + 'x' * 255]
    paths.extend('/' + ''.join(random_source.choices('azAZ09/._+-; \'\\é', k=random_source.randrange(280))) for _ in range(800))
    for discovery, program in itertools.product([0, 1], paths):
        yield 'command', b'\2' + bytes([discovery, program is not None]) + text(program or '')
    diagnostics = ['', 'Host key verification failed', 'REMOTE HOST IDENTIFICATION HAS CHANGED',
                   'Permission denied (publickey).', 'Too many authentication failures', 'telar protocol mismatch',
                   'Connection refused', 'host key verification failed', 'Permission denied',
                   'Permission denied (publickey). Host key verification failed',
                   'telar protocol mismatch\nHost key verification failed']
    for exited, status, diagnostic in itertools.product([0, 1], range(256), diagnostics):
        yield 'failure', b'\3' + bytes([exited, status]) + text(diagnostic)
    errors = ['InvalidMachineId', 'InvalidMachineLabel', 'InvalidRemoteDestination', 'InvalidMachineColor',
              'InvalidRemoteTelarPath', 'InvalidMachineProfiles', 'IncompatibleMachineProfiles', 'TooManyMachines',
              'DuplicateMachineId', 'DuplicateMachineLabel', 'DuplicateMachineDestination', 'UnknownMachine',
              'RemoteDiscoveryUnreadable', 'SshHostKeyRejected', 'SshAuthenticationFailed', 'RemoteTelarMissing',
              'RemoteTelarIncompatible', 'RemoteRuntimeIncompatible', 'RemoteEndpointUnavailable',
              'IncompatibleSchema', 'RuntimeAlreadyRunning', 'InvalidRuntimeDirectory', 'UnexpectedError']
    for error in errors:
        yield 'policy', b'\4' + text(error)


def prepare(repository, output):
    shutil.copytree(repository / 'src/client/machines', output / 'machines')
    shutil.copytree(repository / 'src/client/transport', output / 'transport')
    shutil.copytree(repository / 'src/core/schema', output / 'schema')
    shutil.copy2(repository / 'src/core/remote_telar.zig', output / 'remote_telar.zig')
    (output / 'core.zig').write_text('pub const SchemaId = @import("schema/handshake.zig").SchemaId;\n'
                                   'pub const schema_id = @import("schema/handshake.zig").schema_id;\n'
                                   'pub const remote_telar = @import("remote_telar.zig");\n')
    (output / 'protocol.zig').write_text(protocol)
    (output / 'facades.zig').write_text('pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };\n')
    (output / 'probe.zig').write_text(reference)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'telar-core',
               '-Mroot=' + str(output / 'probe.zig'), '-Mtelar-core=' + str(output / 'core.zig'),
               '-femit-bin=' + str(output / 'original')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    return command


def replies(data, cases):
    offset = 0

    def skip_text(position):
        length, = struct.unpack_from('<H', data, position)
        return position + 2 + length

    for kind, _ in cases:
        start = offset
        if kind == 'policy':
            offset += 2
        elif kind == 'failure':
            offset = skip_text(offset)
        elif kind == 'command':
            offset = skip_text(offset + 1)
        else:
            success = data[offset]
            offset += 1
            for _ in range(4 if success else 1):
                offset = skip_text(offset)
            if success:
                offset += 1
        yield data[start:offset]
    assert offset == len(data)


def main():
    parser = argparse.ArgumentParser(description='Compare remote discovery, commands and SSH error policies with unchanged Zig sources')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command = prepare(repository, output)
    source = (repository / 'src/core/schema/handshake.zig').read_text()
    version = source.split('pub const schema_version:')[1].split('"')[1]
    fingerprint = source.split('pub const schema_id:')[1].split('"')[1]
    path_limit = os.pathconf('/', 'PC_PATH_MAX')
    cases = list(fixtures(path_limit, (version + fingerprint).encode()))
    payload = b''.join(value for _, value in cases)
    (output / 'input.bin').write_bytes(payload)
    binaries = dict(original=output / 'original', cpp=options.build_dir.resolve() / 'gui-machine-remote-probe')
    outputs = {}
    for name, binary in binaries.items():
        result = subprocess.run([str(binary)], input=payload, capture_output=True, check=True)
        (output / (name + '-output.bin')).write_bytes(result.stdout)
        (output / (name + '-run.log')).write_bytes(result.stderr)
        outputs[name] = result.stdout
    if outputs['cpp'] != outputs['original']:
        mismatches = [dict(index=index, kind=cases[index][0], input=repr(cases[index][1]), original=repr(expected), cpp=repr(actual))
                      for index, (expected, actual) in enumerate(zip(replies(outputs['original'], cases), replies(outputs['cpp'], cases)))
                      if expected != actual]
        (output / 'mismatches.json').write_text(json.dumps(mismatches, indent=2) + '\n')
        raise AssertionError(f'{len(mismatches)} remote cases differ; evidence retained in {output}')
    original_sources = ['src/client/machines/' + name for name in ['Discovery.zig', 'LaunchDefaults.zig', 'remote.zig', 'machine_connection.zig']]
    original_sources += ['src/core/schema/handshake.zig', 'src/core/remote_telar.zig']
    cpp_sources = ['services/gui-cpp/machines/' + name for name in ['discovery.hpp', 'connection_policy.hpp', 'remote_command.hpp', 'failure.hpp', 'field_rules.hpp', 'limits.hpp']]
    cpp_sources += ['services/gui-cpp/tools/machine_remote_probe.cpp', 'services/gui-cpp/tools/check_machine_remote.py']
    result = dict(cases=len(cases), cases_by_kind=dict(Counter(kind for kind, _ in cases)), native_path_limit=path_limit,
                  input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(outputs['cpp']),
                  output_sha256=hashlib.sha256(outputs['cpp']).hexdigest(), reference_command=command,
                  binary_sha256={name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in binaries.items()},
                  source_sha256={name: hashlib.sha256((repository / name).read_bytes()).hexdigest() for name in original_sources + cpp_sources},
                  scope='Unchanged original Discovery, remoteCommand, sshFailure, permanent and setupRepairs procedures. Minimal core facade supplies original schema and program validation. No subprocess, live SSH, profile filesystem, machine switching, visual or comparative performance acceptance.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ['cases', 'cases_by_kind', 'native_path_limit', 'output_bytes', 'output_sha256']}, indent=2))


if __name__ == '__main__':
    main()
