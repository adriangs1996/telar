//! `telar --machine LABEL COMMAND…`: run one telar command on a saved
//! machine over its managed SSH connection, or here when the label is this
//! machine's. A failure there is a failure: nothing falls back to here.
const client = @import("telar-client");
const core = @import("telar-core");
const std = @import("std");
const dispatch_argv = @import("dispatch_argv.zig");
const SshOptions = client.SshOptions;

/// Where a label points.
pub const Target = union(enum) {
    local,
    remote: core.MachineProfile,
};

/// Exit status `ssh` reports for its own failures.
const ssh_failure: u8 = 255;
/// The longest remote command line, in bytes.
const max_command_bytes = 64 * 1024;

/// Finds the machine a label names: a saved profile first, then this
/// machine's own label.
///
/// ```zig
/// switch (try machine_dispatch.resolve(process_init, "box")) { ... }
/// ```
pub fn resolve(init: std.process.Init, label: []const u8) !Target {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try client.profile_file.path(init.minimal.environ, &path_buffer);
    const profiles = try client.profile_file.load(init.io, init.gpa, path);

    if (profiles.find(label)) |row| {
        return .{ .remote = profiles.rows[row] };
    }

    var local_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    if (std.mem.eql(u8, label, client.profile_file.localLabel(&profiles, &local_buffer))) {
        return .local;
    }

    return error.UnknownMachine;
}

/// Runs `argv[1..]` as a telar command on the machine and returns the exit
/// status it reported. Standard input, output and error pass through, so
/// streaming commands such as `pane watch` work unchanged.
///
/// ```zig
/// const status = try machine_dispatch.forward(process_init, &profile, argv);
/// ```
pub fn forward(init: std.process.Init, profile: *const core.MachineProfile, argv: []const [*:0]const u8) !u8 {
    const command = try init.gpa.alloc(u8, max_command_bytes);
    defer init.gpa.free(command);

    const remote_command = try encodeCommand(argv[1..], command);
    const options = try SshOptions.prepare(init.io, init.minimal.environ, profile.destination());
    const managed = options.arguments();

    var child = try std.process.spawn(init.io, .{
        .argv = &(.{ "ssh", "-T" } ++ managed ++ .{ "--", profile.destination(), remote_command }),
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(init.io);

    return switch (term) {
        .exited => |code| code,
        else => ssh_failure,
    };
}

/// Decodes the words `forward` sent into an argv whose element 0 is the
/// program name, ready for the command parser. The caller frees it with
/// `freeDecoded`.
///
/// ```zig
/// const argv = try machine_dispatch.decode(gpa, words);
/// defer machine_dispatch.freeDecoded(gpa, argv);
/// ```
pub fn decode(gpa: std.mem.Allocator, words: []const [*:0]const u8) ![]const [*:0]const u8 {
    const argv = try gpa.alloc([*:0]const u8, words.len + 1);
    var decoded: usize = 0;
    errdefer {
        for (argv[1 .. 1 + decoded]) |argument| {
            gpa.free(std.mem.span(argument));
        }

        gpa.free(argv);
    }

    argv[0] = "telar";
    for (words, 1..) |word, index| {
        argv[index] = try dispatch_argv.decode(gpa, std.mem.span(word));
        decoded += 1;
    }

    return argv;
}

pub fn freeDecoded(gpa: std.mem.Allocator, argv: []const [*:0]const u8) void {
    for (argv[1..]) |argument| {
        gpa.free(std.mem.span(argument));
    }

    gpa.free(argv);
}

fn encodeCommand(arguments: []const [*:0]const u8, buffer: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writer.writeAll("telar dispatch-argv") catch return error.MachineCommandTooLong;

    for (arguments) |argument| {
        const text = std.mem.span(argument);
        const len = 1 + dispatch_argv.encodedLength(text.len);
        if (writer.unusedCapacityLen() < len) {
            return error.MachineCommandTooLong;
        }

        const word = writer.writableSlice(len) catch return error.MachineCommandTooLong;
        word[0] = ' ';
        _ = try dispatch_argv.encode(text, word[1..]);
    }

    return writer.buffered();
}

test "the remote command holds only shell-inert words that decode back" {
    var buffer: [256]u8 = undefined;
    const command = try encodeCommand(&.{ "pane", "send-keys", "--current", "it's $(x)" }, &buffer);

    var words = std.mem.tokenizeScalar(u8, command, ' ');
    try std.testing.expectEqualStrings("telar", words.next().?);
    try std.testing.expectEqualStrings("dispatch-argv", words.next().?);

    var sent: [4][*:0]const u8 = undefined;
    var storage: [4][64:0]u8 = undefined;
    var count: usize = 0;
    while (words.next()) |word| : (count += 1) {
        for (word) |byte| {
            try std.testing.expect(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_');
        }

        @memcpy(storage[count][0..word.len], word);
        storage[count][word.len] = 0;
        sent[count] = storage[count][0..word.len :0];
    }

    const argv = try decode(std.testing.allocator, sent[0..count]);
    defer freeDecoded(std.testing.allocator, argv);

    try std.testing.expectEqualStrings("telar", std.mem.span(argv[0]));
    try std.testing.expectEqualStrings("it's $(x)", std.mem.span(argv[4]));
}

test "a command too long for the buffer is refused" {
    var buffer: [24]u8 = undefined;
    try std.testing.expectError(error.MachineCommandTooLong, encodeCommand(&.{ "pane", "list", "--json" }, &buffer));
}
