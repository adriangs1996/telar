//! OSC 133 command-zone tracker for one PTY.

const std = @import("std");
const OscTracker = @import("OscTracker.zig");
const OscCollected = @import("OscCollected.zig");

pub const max_command_bytes = 64 * 1024;
pub const max_osc_bytes = 8 * 1024;

pub const Status = enum {
    completed,
    interrupted,
};

pub fn parseExitCode(options: []const u8) ?i32 {
    const first = options[0 .. std.mem.indexOfScalar(u8, options, ';') orelse options.len];
    if (first.len == 0) {
        return null;
    }
    return std.fmt.parseInt(i32, first, 10) catch null;
}

pub fn percentDecode(input: []const u8, output: []u8) ?usize {
    var source: usize = 0;
    var destination: usize = 0;
    while (source < input.len) {
        if (destination == output.len) {
            return null;
        }
        if (input[source] == '%') {
            if (source + 2 >= input.len) {
                return null;
            }
            const high = std.fmt.charToDigit(input[source + 1], 16) catch return null;
            const low = std.fmt.charToDigit(input[source + 2], 16) catch return null;
            output[destination] = @intCast(high * 16 + low);
            source += 3;
        } else {
            output[destination] = input[source];
            source += 1;
        }
        destination += 1;
    }
    return destination;
}

test "tracks command lifecycle across chunk boundaries" {
    var tracker = OscTracker.init("/work");
    var collected: OscCollected = .{};
    tracker.feed(.{
        .bytes = "\x1b]133;A\x07$ \x1b]133;B\x07",
        .clock = .{ .real_ms = 100, .awake_ns = 1000 },
    }, &collected);
    _ = tracker.input("echo hi\r\n");
    tracker.feed(.{
        .bytes = "\x1b]133;C\x07",
        .clock = .{ .real_ms = 150, .awake_ns = 1000 },
    }, &collected);
    tracker.feed(.{
        .bytes = "hi\r\n\x1b]133;D;0\x07",
        .clock = .{ .real_ms = 200, .awake_ns = 51_000 },
    }, &collected);

    try std.testing.expectEqual(@as(usize, 1), collected.count);
    try std.testing.expectEqualStrings("echo hi\r\n", collected.last.?.bytes);
    try std.testing.expectEqualStrings("/work", collected.last.?.cwd);
    try std.testing.expectEqual(@as(?i32, 0), collected.last.?.exit_code);
    try std.testing.expectEqual(@as(i64, 50_000), collected.last.?.duration_ns);
}

test "updates cwd from OSC 7 and reports interrupted commands" {
    var tracker = OscTracker.init("/old");
    var collected: OscCollected = .{};
    tracker.feed(.{
        .bytes = "\x1b]7;file://host/tmp/a%20b\x07\x1b]133;B\x07",
        .clock = .{ .real_ms = 20, .awake_ns = 100 },
    }, &collected);
    _ = tracker.input("make\r\n");
    tracker.feed(.{
        .bytes = "\x1b]133;C\x07",
        .clock = .{ .real_ms = 20, .awake_ns = 100 },
    }, &collected);
    tracker.interrupt(.{ .real_ms = 25, .awake_ns = 500 }, &collected);

    try std.testing.expectEqual(@as(usize, 1), collected.count);
    try std.testing.expectEqualStrings("/tmp/a b", collected.last.?.cwd);
    try std.testing.expectEqual(Status.interrupted, collected.last.?.status);
    try std.testing.expect(collected.last.?.exit_code == null);
}

test "an oversized OSC does not prevent later markers" {
    var tracker = OscTracker.init("/");
    var collected: OscCollected = .{};
    var oversized: [max_osc_bytes + 64]u8 = @splat('x');
    tracker.feed(.{ .bytes = "\x1b]", .clock = .{ .real_ms = 0, .awake_ns = 0 } }, &collected);
    tracker.feed(.{ .bytes = &oversized, .clock = .{ .real_ms = 0, .awake_ns = 0 } }, &collected);
    tracker.feed(.{
        .bytes = "\x07\x1b]133;B\x07",
        .clock = .{ .real_ms = 1, .awake_ns = 10 },
    }, &collected);
    _ = tracker.input("pwd\r\n");
    tracker.feed(.{
        .bytes = "\x1b]133;C\x07\x1b]133;D;7\x07",
        .clock = .{ .real_ms = 1, .awake_ns = 10 },
    }, &collected);
    try std.testing.expectEqual(@as(usize, 1), collected.count);
    try std.testing.expectEqual(@as(?i32, 7), collected.last.?.exit_code);
}
