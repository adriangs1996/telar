const client = @import("telar-client");
const window_title = @import("window_title.zig");
const std = @import("std");
const State = @This();

hostname: [window_title.max_hostname_bytes]u8 = undefined,
hostname_len: u8 = 0,
hostname_loaded: bool = false,
title: client.WindowTitleState = .{},

/// Caches the host name on first use; the host terminal does not need it
/// fresh and the lookup never repeats.
///
/// ```zig
/// state.ensureHostname();
/// ```
pub fn ensureHostname(self: *State) void {
    if (self.hostname_loaded) {
        return;
    }

    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = std.posix.gethostname(&buffer) catch "";
    const len = @min(name.len, self.hostname.len);
    @memcpy(self.hostname[0..len], name[0..len]);
    self.hostname_len = @intCast(len);
    self.hostname_loaded = true;
}

pub fn hostnameSlice(self: *const State) []const u8 {
    return self.hostname[0..self.hostname_len];
}

/// Renders the template and writes OSC 0 only when the result differs
/// from the last title sent. An empty template sends nothing.
///
/// ```zig
/// try state.sync(writer, .{ .template = template, .tokens = tokens });
/// ```
pub fn sync(self: *State, writer: *std.Io.Writer, input: client.SyncInput) !void {
    if (input.template.len == 0) {
        return;
    }

    var complete = input.tokens;

    if (complete.hostname.len == 0) {
        self.ensureHostname();
        complete.hostname = self.hostnameSlice();
    }

    _ = try self.title.sync(
        .{
            .context = writer,
            .set = setTitle,
        },
        .{
            .template = input.template,
            .tokens = complete,
        },
    );
}

fn setTitle(context: *anyopaque, title: []const u8) !void {
    const writer: *std.Io.Writer = @ptrCast(@alignCast(context));
    try writer.writeAll("\x1b]0;");
    try writer.writeAll(title);
    try writer.writeAll("\x07");
}
