//! Publishes host snapshots and clipboard requests, then starts client jobs.

const input_limits = @import("input/event.zig");
const client = @import("telar-client");
const native = @import("native/native.zig");
const limit_reached = @import("limit_reached.zig");
const HostServices = @import("host/Services.zig");

pub fn copyWindowTitle(context: *anyopaque, title: []const u8) !void {
    const out: *native.WindowTitle = @ptrCast(@alignCast(context));
    if (title.len >= out.bytes.len) {
        return error.WindowTitleTooLong;
    }

    @memcpy(out.bytes[0..title.len], title);
    out.bytes[title.len] = 0;
    out.len = @intCast(title.len);
}

/// Reports a clipboard request refused at a limit, then returns its error
/// so the caller keeps its own path: the old clipboard stays, nothing is cut.
pub fn refuseHostRequest(app: *client.Client, err: anyerror, bytes: usize) anyerror {
    const limit = switch (err) {
        error.ClipboardTooLarge => input_limits.clipboard_limit,
        error.HostRequestsFull => HostServices.limit,
        else => return err,
    };
    client.limit_reached.report(
        app,
        .{
            .limit = limit,
            .requested = if (err == error.ClipboardTooLarge) bytes else HostServices.capacity + 1,
        },
    );

    return err;
}
