//! Host-level notification adapters: the outer terminal's OSC 9 channel and
//! the operating system's notification service.

const max_notification_title_bytes = @import("telar-core").max_notification_title_bytes;
const max_notification_message_bytes = @import("telar-core").max_notification_message_bytes;
const std = @import("std");
const Payload = @import("Payload.zig");
const builtin = @import("builtin");

pub const max_payload_bytes = max_notification_title_bytes + max_notification_message_bytes + 8;

const command_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(3) },
};

/// Posts one system notification. Runs on a worker; failure is reported but
/// never retried.
///
/// ```zig
/// try notify(io, payload);
/// ```
pub fn notify(io: std.Io, payload: Payload) !void {
    switch (builtin.os.tag) {
        .macos => {
            var script_buffer: [max_payload_bytes + 64]u8 = undefined;
            const script = std.fmt.bufPrint(&script_buffer, "display notification \"{s}\" with title \"{s}\"", .{
                payload.messageSlice(),
                payload.titleSlice(),
            }) catch return error.NotificationUnavailable;
            if (!commandSucceeded(io, &.{ "/usr/bin/osascript", "-e", script })) {
                return error.NotificationUnavailable;
            }
        },
        .linux => {
            if (!commandSucceeded(io, &.{ "notify-send", payload.titleSlice(), payload.messageSlice() })) {
                return error.NotificationUnavailable;
            }
        },
        else => return error.NotificationUnavailable,
    }
}

/// Copies text with quotes, control bytes and backslashes removed, so a
/// payload can be embedded in an OSC string or a quoted script argument.
pub fn copySanitized(storage: []u8, text: []const u8) u8 {
    var len: usize = 0;
    for (text) |byte| {
        if (len == storage.len) {
            break;
        }
        if (byte < 0x20 or byte == 0x7f or byte == '"' or byte == '\\') {
            continue;
        }
        storage[len] = byte;
        len += 1;
    }
    return @intCast(len);
}

fn commandSucceeded(io: std.Io, argv: []const []const u8) bool {
    const gpa = std.heap.page_allocator;
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = command_timeout,
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    return switch (result.term) {
        .exited => |status| status == 0,
        else => false,
    };
}

test "payloads drop quotes and control bytes and stay bounded" {
    const payload = Payload.init("Agent \"done\"\x1b", "line\nbreak\\end");

    try std.testing.expectEqualStrings("Agent done", payload.titleSlice());
    try std.testing.expectEqualStrings("linebreakend", payload.messageSlice());
}
