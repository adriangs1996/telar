//! Bounded external command worker for configured bar data sources.

const std = @import("std");
const CommandType = @import("telar-client").BarCommand;
const Output = @import("Output.zig");
const max_command_args_module = @import("telar-client").max_command_args;
const max_text_bytes_module = @import("telar-client").max_text_bytes;
const builtin = @import("builtin");

pub fn run(io: std.Io, command: CommandType) !Output {
    var argument_storage: [max_command_args_module][]const u8 = undefined;
    const argv = command.argumentSlice(&argument_storage);
    if (argv.len == 0) {
        return error.EmptyBarCommand;
    }

    const allocator = std.heap.page_allocator;
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_text_bytes_module + 2),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = .fromMilliseconds(command.timeout_ms),
        } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |status| {
            if (status != 0) {
                return error.BarCommandFailed;
            }
        },
        else => return error.BarCommandFailed,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len > max_text_bytes_module) {
        return error.BarCommandOutputTooLong;
    }
    for (trimmed) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidBarCommandOutput;
        }
    }
    if (!std.unicode.utf8ValidateSlice(trimmed)) {
        return error.InvalidBarCommandOutput;
    }

    var output: Output = .{};
    @memcpy(output.bytes[0..trimmed.len], trimmed);
    output.len = @intCast(trimmed.len);
    return output;
}

test "command output is an owned bounded value" {
    var output: Output = .{};
    @memcpy(output.bytes[0..5], "quota");
    output.len = 5;

    try std.testing.expectEqualStrings("quota", output.slice());
}

test "command runner executes argv directly and validates one display line" {
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    var command: CommandType = .{
        .generation = 1,
        .interval_ns = std.time.ns_per_s,
        .timeout_ms = 1_000,
    };
    try command.appendArgument("/bin/sh");
    try command.appendArgument("-c");
    try command.appendArgument("printf 'quota 74%%\\n'");

    const output = try run(std.testing.io, command);

    try std.testing.expectEqualStrings("quota 74%", output.slice());

    var invalid = command;
    invalid.argument_count = 0;
    invalid.byte_len = 0;
    try invalid.appendArgument("/bin/sh");
    try invalid.appendArgument("-c");
    try invalid.appendArgument("printf 'first\\nsecond\\n'");

    try std.testing.expectError(error.InvalidBarCommandOutput, run(std.testing.io, invalid));
}
