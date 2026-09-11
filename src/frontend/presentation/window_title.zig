//! Host window title derived from client state. The host terminal keeps the
//! last title it was given, so the presenter sends OSC 0 only when the
//! rendered title changes.

const max_title_bytes = @import("telar-client").max_title_bytes;
const render = @import("telar-client").render;
const std = @import("std");
const State = @import("State.zig");

pub const max_hostname_bytes = 64;

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
    var writer = std.Io.Writer.fixed(&output);
    var state: State = .{};

    try state.sync(&writer, .{ .template = "", .tokens = .{ .workspace = "a" } });
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);

    try state.sync(&writer, .{ .template = "{workspace}", .tokens = .{ .workspace = "a" } });
    try state.sync(&writer, .{ .template = "{workspace}", .tokens = .{ .workspace = "a" } });
    try std.testing.expectEqualStrings("\x1b]0;a\x07", writer.buffered());

    try state.sync(&writer, .{ .template = "{workspace}", .tokens = .{ .workspace = "b" } });
    try std.testing.expectEqualStrings("\x1b]0;a\x07\x1b]0;b\x07", writer.buffered());
}
