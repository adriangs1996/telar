//! Host window title derived from client state. The host terminal keeps the
//! last title it was given, so the presenter sends OSC 0 only when the
//! rendered title changes.

const std = @import("std");

const Io = std.Io;

pub const max_title_bytes = 256;
pub const max_hostname_bytes = 64;

pub const Tokens = struct {
    workspace: []const u8 = "",
    tab: []const u8 = "",
    pane_title: []const u8 = "",
    hostname: []const u8 = "",
};

pub const State = struct {
    hostname: [max_hostname_bytes]u8 = undefined,
    hostname_len: u8 = 0,
    hostname_loaded: bool = false,
    sent: [max_title_bytes]u8 = undefined,
    sent_len: u16 = 0,
    ever_sent: bool = false,

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
    /// try state.sync(writer, template, tokens);
    /// ```
    pub fn sync(state: *State, writer: *Io.Writer, template: []const u8, tokens: Tokens) !void {
        if (template.len == 0) {
            return;
        }

        var buffer: [max_title_bytes]u8 = undefined;
        var complete = tokens;
        if (complete.hostname.len == 0) {
            state.ensureHostname();
            complete.hostname = state.hostnameSlice();
        }
        const title = render(&buffer, template, complete);
        if (state.ever_sent and std.mem.eql(u8, state.sent[0..state.sent_len], title)) {
            return;
        }

        try writer.writeAll("\x1b]0;");
        try writer.writeAll(title);
        try writer.writeAll("\x07");
        @memcpy(state.sent[0..title.len], title);
        state.sent_len = @intCast(title.len);
        state.ever_sent = true;
    }
};

/// Substitutes `{workspace}`, `{tab}`, `{pane_title}` and `{hostname}`.
/// Unknown braces are copied verbatim; the result is cut on a UTF-8 boundary.
///
/// ```zig
/// const title = render(&buffer, "{hostname}: {workspace}", tokens);
/// ```
pub fn render(buffer: *[max_title_bytes]u8, template: []const u8, tokens: Tokens) []const u8 {
    var len: usize = 0;
    var index: usize = 0;
    while (index < template.len) {
        if (template[index] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, index, '}')) |close| {
                const name = template[index + 1 .. close];
                if (tokenValue(name, tokens)) |value| {
                    len = append(buffer, len, value);
                    index = close + 1;
                    continue;
                }
            }
        }

        len = append(buffer, len, template[index .. index + 1]);
        index += 1;
    }

    while (len > 0 and (buffer[len - 1] & 0xc0) == 0x80) : (len -= 1) {}
    if (len > 0 and buffer[len - 1] >= 0xc0 and !std.unicode.utf8ValidateSlice(buffer[0..len])) {
        len -= 1;
    }

    return buffer[0..len];
}

fn tokenValue(name: []const u8, tokens: Tokens) ?[]const u8 {
    if (std.mem.eql(u8, name, "workspace")) {
        return tokens.workspace;
    }
    if (std.mem.eql(u8, name, "tab")) {
        return tokens.tab;
    }
    if (std.mem.eql(u8, name, "pane_title")) {
        return tokens.pane_title;
    }
    if (std.mem.eql(u8, name, "hostname")) {
        return tokens.hostname;
    }
    return null;
}

fn append(buffer: *[max_title_bytes]u8, len: usize, value: []const u8) usize {
    const room = buffer.len - len;
    const count = @min(room, value.len);
    @memcpy(buffer[len .. len + count], value[0..count]);
    return len + count;
}

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

    try state.sync(&writer, "", .{ .workspace = "a" });
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);

    try state.sync(&writer, "{workspace}", .{ .workspace = "a" });
    try state.sync(&writer, "{workspace}", .{ .workspace = "a" });
    try std.testing.expectEqualStrings("\x1b]0;a\x07", writer.buffered());

    try state.sync(&writer, "{workspace}", .{ .workspace = "b" });
    try std.testing.expectEqualStrings("\x1b]0;a\x07\x1b]0;b\x07", writer.buffered());
}
