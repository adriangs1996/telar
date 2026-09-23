//! Posts notices through the operating system's notification service.

const core = @import("telar-core");
const data = @import("model");
const std = @import("std");
const builtin = @import("builtin");

const max_payload_bytes = core.max_notification_title_bytes + core.max_notification_message_bytes + 8;

const command_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(3) },
};

/// Posts one system notification. Runs on a worker; failure is reported but
/// never retried.
///
/// ```zig
/// try post(io, payload);
/// ```
pub fn post(io: std.Io, payload: data.NotificationPayload) !void {
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
