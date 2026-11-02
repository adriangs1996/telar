import argparse
import datetime
import hashlib
import itertools
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess

from check_activity_order import declaration
from check_notification_center import run
from check_notification_effects import text
from check_task_labels import function_source


reference = r'''
const original_std = @import("std");
const Payload = @import("NotificationPayload.zig");
__BUDGET__
const Host = enum { macos, linux, windows, other };
var success_mask: u8 = 0;
var attempt: u3 = 0;
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| {
        const value = getchar();
        if (value < 0) return error.TruncatedInput;
        byte.* = @intCast(value);
    }
    return @bitCast(bytes);
}
fn write(value: anytype) !void {
    for (original_std.mem.asBytes(&value)) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}
fn readText(allocator: original_std.mem.Allocator) ![]const u8 {
    const bytes = try allocator.alloc(u8, try read(u16));
    for (bytes) |*byte| byte.* = try read(u8);
    return bytes;
}
fn writeText(value: []const u8) !void {
    try write(@as(u16, @intCast(value.len)));
    for (value) |byte| try write(byte);
}
const Adapter = struct {
    const std = struct { const Io = void; const fmt = original_std.fmt; };
    const core = @import("telar-core");
    const data = struct { const NotificationPayload = Payload; };
    const builtin = struct { const os = struct { var tag: Host = .macos; }; };
    const max_payload_bytes = core.max_notification_title_bytes + core.max_notification_message_bytes + 8;
    fn MessageBeep(_: u32) i32 { return 0; }
    fn commandSucceeded(_: std.Io, argv: []const []const u8) bool {
        write(@as(u8, 1)) catch @panic("WriteFailed");
        write(@as(u8, @intCast(argv.len))) catch @panic("WriteFailed");
        for (argv) |value| writeText(value) catch @panic("WriteFailed");
        const succeeded = success_mask & (@as(u8, 1) << attempt) != 0;
        attempt += 1;
        return succeeded;
    }
    __PLAY__
    __LINUX__
    __POST__
};
pub fn main() !void {
    try write(@as(u16, @intCast(Budget.Message.inbox_capacity)));
    while (true) {
        const operation = getchar();
        if (operation < 0) return;
        Adapter.builtin.os.tag = if (try read(u8) == 0) .macos else .linux;
        attempt = 0;
        var succeeded = false;
        if (operation == 0) {
            const sound: Adapter.core.AgentSound = @enumFromInt(try read(u8));
            success_mask = try read(u8);
            if (Adapter.play({}, sound)) |_| { succeeded = true; } else |_| {}
        } else {
            success_mask = try read(u8);
            var arena: original_std.heap.ArenaAllocator = .init(original_std.heap.page_allocator);
            defer arena.deinit();
            const title = try readText(arena.allocator());
            const message = try readText(arena.allocator());
            if (Adapter.post({}, Payload.init(title, message))) |_| { succeeded = true; } else |_| {}
        }
        try write(@as(u8, 0));
        try write(@as(u8, @intFromBool(succeeded)));
    }
}
'''


def prepare(root, work):
    sound = (root / 'src/client/agents/sound_playback.zig').read_text()
    notice = (root / 'src/client/notifications/system_notification.zig').read_text()
    probe = reference.replace('__PLAY__', function_source(sound, 'play')).replace('__LINUX__', function_source(sound, 'playLinux')).replace('__POST__', function_source(notice, 'post'))
    kinds = declaration((root / 'src/client/execution/Job.zig').read_text(), 'Kind')
    machines = declaration((root / 'src/client/machines/Machines.zig').read_text(), 'capacity')
    inbox = declaration((root / 'lib/mailbox/GenericInbox.zig').read_text(), 'default_capacity')
    event = (root / 'src/gui/gui_event.zig').read_text()
    tickets = declaration(event, 'tickets_per_machine')
    capacity = declaration(event, 'inbox_capacity')
    budget = 'const Budget = struct { const std = original_std; const client = struct { const Machines = struct { const core = @import("telar-core"); ' + machines + ' }; const Job = struct { ' + kinds + ' }; }; const Inbox = struct { ' + inbox + ' }; const Message = struct { ' + tickets + capacity + ' }; };'
    probe = probe.replace('__BUDGET__', budget)
    (work / 'probe.zig').write_text(probe)
    shutil.copy2(root / 'src/model/notifications/NotificationPayload.zig', work / 'NotificationPayload.zig')
    types = (root / 'src/core/schema/types.zig').read_text()
    core = '\n'.join(declaration(types, name) for name in ['AgentSound', 'max_notification_title_bytes', 'max_notification_message_bytes'])
    core += '\npub const MachineProfiles = struct { ' + declaration((root / 'src/core/MachineProfiles.zig').read_text(), 'capacity') + ' };'
    (work / 'core.zig').write_text(core)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'telar-core', f'-Mroot={work / "probe.zig"}', f'-Mtelar-core={work / "core.zig"}', f'-femit-bin={work / "original"}']
    with (work / 'reference-build.log').open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True, timeout=180)
    return command


def fixtures():
    for host, sound, mask in itertools.product(range(2), range(2), range(32)):
        yield bytes([0, host, sound, mask])
    labels = ['', 'Telar', '--app-name=other', 'a"b\\c\n\t', 'UTF-8: á日🚀', 'a' * 95 + 'á', 'x' * 510 + '日', '\x7f\x1b"\\' * 150]
    for host, succeeds, title, message in itertools.product(range(2), range(2), labels, labels):
        yield bytes([1, host, succeeds]) + text(title) + text(message)
    generator = random.Random(0xA0D10)
    alphabet = ['a', ' ', '\n', '\t', '\\', '"', '日', 'á', '🚀', '\x7f']
    for index in range(2000):
        title = ''.join(generator.choice(alphabet) for _ in range(generator.choice([0, 8, 96, 128])))
        message = ''.join(generator.choice(alphabet) for _ in range(generator.choice([0, 16, 512, 600])))
        yield bytes([1, generator.randrange(2), generator.randrange(2)]) + text(title) + text(message)


def frames(data):
    position = 0
    while position < len(data):
        start = position
        commands = []
        while data[position] != 0:
            assert data[position] == 1
            count = data[position + 1]
            position += 2
            arguments = []
            for _ in range(count):
                length = struct.unpack_from('<H', data, position)[0]
                position += 2
                arguments.append(data[position:position + length])
                position += length
            commands.append(arguments)
        success = data[position + 1]
        position += 2
        yield data[start:position], commands, success
    assert position == len(data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    command = prepare(root, work)
    cases = list(fixtures())
    payload = b''.join(cases)
    (work / 'input.bin').write_bytes(payload)
    expected = run(work / 'original', payload, work, 'original')
    actual = run(options.build_dir.resolve() / 'gui-host-commands-probe', payload, work, 'cpp')
    original_capacity = struct.unpack_from('<H', expected)[0]
    assert original_capacity == struct.unpack_from('<H', actual)[0]
    original_frames = list(frames(expected[2:]))
    cpp_frames = list(frames(actual[2:]))
    assert len(original_frames) == len(cpp_frames) == len(cases)
    exact = 0
    guarded_linux = 0
    for index, (case, reference_frame, cpp_frame) in enumerate(zip(cases, original_frames, cpp_frames)):
        if case[:2] == b'\x01\x01':
            raw, commands, succeeded = cpp_frame
            assert len(commands) == 1 and commands[0][1] == b'--', index
            guarded = [commands[0][:1] + commands[0][2:]]
            assert (guarded, succeeded) == reference_frame[1:], index
            guarded_linux += 1
        else:
            assert reference_frame[0] == cpp_frame[0], index
            exact += 1
    sources = ['src/client/agents/sound_playback.zig', 'src/client/notifications/system_notification.zig', 'src/model/notifications/NotificationPayload.zig', 'src/core/schema/types.zig']
    sources += ['src/client/execution/Job.zig', 'src/client/machines/Machines.zig', 'lib/mailbox/GenericInbox.zig', 'src/gui/gui_event.zig', 'src/core/MachineProfiles.zig', 'services/gui-cpp/application/host_effects.hpp']
    sources += ['services/gui-cpp/' + name for name in ['platform/command_line.hpp', 'platform/sound_commands.hpp', 'platform/notification_commands.hpp', 'application/notification_payload.hpp', 'tools/host_commands_probe.cpp', 'tools/check_host_commands.py']]
    record = dict(
        recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        frames=len(cases),
        original_inbox_capacity=original_capacity,
        sound_frames=128,
        byte_exact_frames=exact,
        linux_notification_frames_with_explicit_option_guard=guarded_linux,
        input_sha256=hashlib.sha256(payload).hexdigest(),
        original_output_sha256=hashlib.sha256(expected).hexdigest(),
        cpp_output_sha256=hashlib.sha256(actual).hexdigest(),
        source_sha256={name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sources},
        generated_sha256={str(path.relative_to(work)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(work.rglob('*.zig'))},
        reference_command=command,
        scope=(
            'Unchanged original play, playLinux and post functions with recording commandSucceeded, an injected OS tag and void I/O facade. '
            'Uses the unchanged original NotificationPayload and original inbox/machine/timer capacity declarations over type facades. '
            'The notification concurrency bound matches the original total inbox budget; other jobs do not share this Qt service limit. '
            'Complete sound command traces and macOS notice commands match byte for byte for success/failure masks, control bytes, '
            'bounded UTF-8 and both semantic sounds. Linux notice commands deliberately add -- before the original sanitized positional '
            'arguments; both raw outputs are retained, and only this exact guard is removed during explicit semantic comparison. '
            'Does not execute native helpers, verify desktop presentation/audio, or establish process scheduling/performance parity.'
        ),
    )
    (work / 'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print('Matched',len(cases),'host command frames;',exact,'byte exact;',guarded_linux,'Linux notices with explicit option guard')


if __name__ == '__main__':
    main()
