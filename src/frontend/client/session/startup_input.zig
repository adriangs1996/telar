//! Keeps early user input until a pane exists while delivering host replies
//! through the normal presentation parser. Storage saturation fails explicitly.
const console = @import("console");

const StartupInput = @import("StartupInput.zig");
const std = @import("std");

test "startup preserves typing and partial escapes at every reply boundary" {
    const stream = "hello\x1b]10;rgb:ffff/ffff/ffff\x07\x1b[A\x1b]11;rgb:1010/1010/1010\x1b\\!\x1b[";
    for (0..stream.len + 1) |split| {
        var state: StartupInput = .{};
        var capture: Capture = .{};
        try collect(&state, stream[0..split], &capture);
        try collect(&state, stream[split..], &capture);
        try std.testing.expectEqual(@as(usize, 2), capture.replies);
        try std.testing.expectEqualStrings("hello\x1b[A!\x1b[", try state.finish());
    }
}

test "pasted terminal queries remain user data" {
    const bytes = "\x1b[200~\x1b]11;rgb:10/10/10\x07\x1b[201~";
    var state: StartupInput = .{};
    var capture: Capture = .{};
    try collect(&state, bytes, &capture);
    try std.testing.expectEqual(@as(usize, 0), capture.replies);
    try std.testing.expectEqualStrings(bytes, try state.finish());
}

test "startup buffers reject saturation instead of dropping keystrokes" {
    var state: StartupInput = .{};
    var capture: Capture = .{};
    try collect(&state, &(@as([StartupInput.capacity]u8, @splat('x'))), &capture);
    try std.testing.expectError(error.StartupInputOverflow, collect(&state, "x", &capture));
}

fn collect(state: *StartupInput, bytes: []const u8, capture: *Capture) !void {
    var remaining = bytes;
    while (try state.next(&remaining)) |response| {
        try capture.terminalResponse(response);
    }
}

const Capture = struct {
    replies: usize = 0,

    pub fn terminalResponse(self: *Capture, _: console.Event.TerminalResponse) !void {
        self.replies += 1;
    }
};
