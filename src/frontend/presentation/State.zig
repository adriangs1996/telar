const State = @This();
const source_namespace = @import("window_title.zig");
const std = @import("std");
const SyncInput = @import("telar-client").presentation.window_title.SyncInput;
hostname: [source_namespace.max_hostname_bytes]u8 = undefined,
hostname_len: u8 = 0,
hostname_loaded: bool = false,
title: @import("telar-client").presentation.window_title.State = .{},

/// Caches the host name on first use; the host terminal does not need it
/// fresh and the lookup never repeats.
///
/// ```zig
/// state.ensureHostname();
/// ```
pub fn ensureHostname(state: *State) void {
    if (state.hostname_loaded) {
        return;
    }

    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = std.posix.gethostname(&buffer) catch "";
    const len = @min(name.len, state.hostname.len);
    @memcpy(state.hostname[0..len], name[0..len]);
    state.hostname_len = @intCast(len);
    state.hostname_loaded = true;
}

pub fn hostnameSlice(state: *const State) []const u8 {
    return state.hostname[0..state.hostname_len];
}

/// Renders the template and writes OSC 0 only when the result differs
/// from the last title sent. An empty template sends nothing.
///
/// ```zig
/// try state.sync(writer, .{ .template = template, .tokens = tokens });
/// ```
pub fn sync(state: *State, writer: *source_namespace.Io.Writer, input: SyncInput) !void {
    if (input.template.len == 0) {
        return;
    }

    var complete = input.tokens;
    if (complete.hostname.len == 0) {
        state.ensureHostname();
        complete.hostname = state.hostnameSlice();
    }
    try state.title.sync(.{ .context = writer, .set = setTitle }, .{ .template = input.template, .tokens = complete });
}

fn setTitle(context: *anyopaque, title: []const u8) !void {
    const writer: *source_namespace.Io.Writer = @ptrCast(@alignCast(context));
    try writer.writeAll("\x1b]0;");
    try writer.writeAll(title);
    try writer.writeAll("\x07");
}
