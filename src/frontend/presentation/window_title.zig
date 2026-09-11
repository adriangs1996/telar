//! Host window title derived from client state. The host terminal keeps the
//! last title it was given, so the presenter sends OSC 0 only when the
//! rendered title changes.

const std = @import("std");

const Io = std.Io;

pub const max_title_bytes = @import("telar-client").presentation.window_title.max_title_bytes;
pub const max_hostname_bytes = 64;

pub const Tokens = @import("telar-client").presentation.window_title.Tokens;

pub const SyncInput = @import("telar-client").presentation.window_title.SyncInput;

pub const State = struct {
    hostname: [max_hostname_bytes]u8 = undefined,
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
    pub fn sync(state: *State, writer: *Io.Writer, input: SyncInput) !void {
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
        const writer: *Io.Writer = @ptrCast(@alignCast(context));
        try writer.writeAll("\x1b]0;");
        try writer.writeAll(title);
        try writer.writeAll("\x07");
    }
};

/// Substitutes `{workspace}`, `{tab}`, `{pane_title}` and `{hostname}`.
/// Unknown braces are copied verbatim; the result is cut on a UTF-8 boundary.
///
/// ```zig
/// const title = render(&buffer, "{hostname}: {workspace}", tokens);
/// ```
pub const render = @import("telar-client").presentation.window_title.render;

test "render substitutes known tokens and keeps unknown braces" {
    var buffer: [max_title_bytes]u8 = undefined;

    const title = render(&buffer, "{hostname}: {workspace} · {tab} {pane_title} {x}", .{
        .workspace = "telar",
        .tab = "main",
        .pane_title = "vim",
        .hostname = "box",
    });

    try std.testing.expectEqualStrings("box: telar · main vim {x}", title);
}

test "sync writes the title once per change and nothing for an empty template" {
    var output: [512]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    var state: State = .{};

    try state.sync(&writer, .{ .template = "", .tokens = .{ .workspace = "a" } });
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);

    try state.sync(&writer, .{ .template = "{workspace}", .tokens = .{ .workspace = "a" } });
    try state.sync(&writer, .{ .template = "{workspace}", .tokens = .{ .workspace = "a" } });
    try std.testing.expectEqualStrings("\x1b]0;a\x07", writer.buffered());

    try state.sync(&writer, .{ .template = "{workspace}", .tokens = .{ .workspace = "b" } });
    try std.testing.expectEqualStrings("\x1b]0;a\x07\x1b]0;b\x07", writer.buffered());
}
