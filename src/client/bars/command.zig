//! Bounded external command worker for configured bar and panel sources.

const data = @import("model");
const std = @import("std");
const Output = @import("Output.zig");
const builtin = @import("builtin");

const stderr_limit = 4096;
const tab: u8 = '\t';
const line_feed: u8 = '\n';
const carriage_return: u8 = '\r';
const first_printable: u8 = 0x20;
const delete_control: u8 = 0x7f;

/// Runs the argv directly, without a shell. Output handed to a render
/// callback may hold several lines, up to `max_command_output_bytes`; output
/// shown as plain text must be one display line of `max_text_bytes`.
///
/// ```zig
/// var output = try command.run(io, bar_command);
/// defer output.deinit();
/// ```
pub fn run(io: std.Io, command: data.BarCommand) !Output {
    var argument_storage: [data.bar_values.max_command_args][]const u8 = undefined;
    const argv = command.argumentSlice(&argument_storage);
    if (argv.len == 0) {
        return error.EmptyBarCommand;
    }

    const rendered = command.render != null;
    const limit: usize = if (rendered) data.bar_values.max_command_output_bytes else data.bar_values.max_text_bytes + 2;
    const result = try std.process.run(Output.allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(stderr_limit),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = .fromMilliseconds(command.timeout_ms),
        } },
    });
    Output.allocator.free(result.stderr);
    var output: Output = .{ .buffer = result.stdout };
    errdefer output.deinit();

    switch (result.term) {
        .exited => |status| {
            if (status != 0) {
                return error.BarCommandFailed;
            }
        },
        else => return error.BarCommandFailed,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!rendered and trimmed.len > data.bar_values.max_text_bytes) {
        return error.BarCommandOutputTooLong;
    }
    for (trimmed) |byte| {
        const line_break = byte == line_feed or byte == carriage_return or byte == tab;
        if (line_break and rendered) {
            continue;
        }
        if (byte < first_printable or byte == delete_control) {
            return error.InvalidBarCommandOutput;
        }
    }
    if (!std.unicode.utf8ValidateSlice(trimmed)) {
        return error.InvalidBarCommandOutput;
    }

    output.start = @intFromPtr(trimmed.ptr) - @intFromPtr(result.stdout.ptr);
    output.len = trimmed.len;
    return output;
}

test "command runner executes argv directly and validates one display line" {
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    var command: data.BarCommand = .{
        .generation = 1,
        .interval_ns = std.time.ns_per_s,
        .timeout_ms = 1_000,
    };
    try command.appendArgument("/bin/sh");
    try command.appendArgument("-c");
    try command.appendArgument("printf 'quota 74%%\\n'");

    var output = try run(std.testing.io, command);
    defer output.deinit();

    try std.testing.expectEqualStrings("quota 74%", output.slice());

    var invalid = command;
    invalid.argument_count = 0;
    invalid.byte_len = 0;
    try invalid.appendArgument("/bin/sh");
    try invalid.appendArgument("-c");
    try invalid.appendArgument("printf 'first\\nsecond\\n'");

    try std.testing.expectError(error.InvalidBarCommandOutput, run(std.testing.io, invalid));
}

test "command output for a render callback may span lines" {
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    var command: data.BarCommand = .{
        .generation = 1,
        .interval_ns = std.time.ns_per_s,
        .timeout_ms = 1_000,
        .render = .{ .generation = 1, .id = 0 },
    };
    try command.appendArgument("/bin/sh");
    try command.appendArgument("-c");
    try command.appendArgument("printf '{\\n  \"used\": 22\\n}\\n'");

    var output = try run(std.testing.io, command);
    defer output.deinit();

    try std.testing.expectEqualStrings("{\n  \"used\": 22\n}", output.slice());
}
