//! Bounded window-title formatting and a synchronous host-title port.
const std = @import("std");

pub const max_title_bytes = 256;

pub const Sink = struct {
    context: *anyopaque,
    set: *const fn (*anyopaque, []const u8) anyerror!void,
};

pub const State = struct {
    sent: [max_title_bytes]u8 = undefined,
    sent_len: u16 = 0,
    ever_sent: bool = false,

    /// Sends changed text through the host port. Failure preserves the cache.
    /// Example: `try state.sync(sink, .{ .template = "{tab}", .tokens = tokens });`.
    pub fn sync(state: *State, sink: Sink, input: SyncInput) !void {
        if (input.template.len == 0) {
            return;
        }

        var buffer: [max_title_bytes]u8 = undefined;
        const title = render(&buffer, input.template, input.tokens);
        if (state.ever_sent and std.mem.eql(u8, state.sent[0..state.sent_len], title)) {
            return;
        }

        try sink.set(sink.context, title);
        @memcpy(state.sent[0..title.len], title);
        state.sent_len = @intCast(title.len);
        state.ever_sent = true;
    }
};

pub const Tokens = struct {
    workspace: []const u8 = "",
    tab: []const u8 = "",
    pane_title: []const u8 = "",
    hostname: []const u8 = "",
};

pub const SyncInput = struct {
    template: []const u8,
    tokens: Tokens,
};

/// Expands a bounded configuration template into printable, complete UTF-8.
/// Example: `const text = render(&buffer, "{tab} - telar", .{ .tab = "build" });`.
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

    var end: usize = 0;
    var output_len: usize = 0;
    while (end < len) {
        const size = std.unicode.utf8ByteSequenceLength(buffer[end]) catch break;
        if (size > len - end) {
            break;
        }

        const codepoint = std.unicode.utf8Decode(buffer[end..][0..size]) catch break;
        if (codepoint >= 0x20 and !(codepoint >= 0x7f and codepoint <= 0x9f)) {
            std.mem.copyForwards(u8, buffer[output_len..][0..size], buffer[end..][0..size]);
            output_len += size;
        }

        end += size;
    }

    return buffer[0..output_len];
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

const Capture = struct {
    count: usize = 0,
    fail: bool = false,
    text: [max_title_bytes]u8 = undefined,
    len: usize = 0,

    fn set(context: *anyopaque, title: []const u8) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        if (capture.fail) {
            return error.TitleFailed;
        }

        @memcpy(capture.text[0..title.len], title);
        capture.len = title.len;
        capture.count += 1;
    }
};

test "window titles use a host port and retry failed changes without a terminal writer" {
    var state: State = .{};
    var capture: Capture = .{ .fail = true };
    const sink: Sink = .{ .context = &capture, .set = Capture.set };
    const input: SyncInput = .{ .template = "{workspace}", .tokens = .{ .workspace = "café" } };
    try std.testing.expectError(error.TitleFailed, state.sync(sink, input));
    try std.testing.expect(!state.ever_sent);
    capture.fail = false;
    try state.sync(sink, input);
    try state.sync(sink, input);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("café", capture.text[0..capture.len]);
}

test "window title truncation preserves complete Unicode and excludes host control bytes" {
    var buffer: [max_title_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("café漢", render(&buffer, "café漢", .{}));
    const source = "a" ** (max_title_bytes - 1) ++ "漢";
    try std.testing.expectEqualStrings("a" ** (max_title_bytes - 1), render(&buffer, "{tab}", .{ .tab = source }));
    try std.testing.expectEqualStrings("safe]0;title", render(&buffer, "safe\x1b]0;title\x07\x7f", .{}));
    try std.testing.expectEqualStrings("safetitle", render(&buffer, "safe\u{009b}title", .{}));
    try std.testing.expectEqualStrings("safe", render(&buffer, "safe\xff", .{}));
}
