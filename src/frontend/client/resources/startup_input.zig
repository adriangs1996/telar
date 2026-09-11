//! Keeps early user input until a pane exists while delivering host replies
//! through the normal presentation parser. Storage saturation fails explicitly.

const StartupInputState = @import("StartupInputState.zig");
const Capture = @import("Capture.zig");
const std = @import("std");

test "startup preserves typing and partial escapes at every reply boundary" {
    const stream = "hello\x1b]10;rgb:ffff/ffff/ffff\x07\x1b[A\x1b]11;rgb:1010/1010/1010\x1b\\!\x1b[";
    for (0..stream.len + 1) |split| {
        var state: StartupInputState = .{};
        var capture: Capture = .{};
        try state.feed(stream[0..split], &capture);
        try state.feed(stream[split..], &capture);
        try std.testing.expectEqual(@as(usize, 2), capture.replies);
        try std.testing.expectEqualStrings("hello\x1b[A!\x1b[", try state.finish());
    }
}

test "pasted terminal queries remain user data" {
    const bytes = "\x1b[200~\x1b]11;rgb:10/10/10\x07\x1b[201~";
    var state: StartupInputState = .{};
    var capture: Capture = .{};
    try state.feed(bytes, &capture);
    try std.testing.expectEqual(@as(usize, 0), capture.replies);
    try std.testing.expectEqualStrings(bytes, try state.finish());
}

test "startup buffers reject saturation instead of dropping keystrokes" {
    var state: StartupInputState = .{};
    var capture: Capture = .{};
    try state.feed(&(@as([StartupInputState.capacity]u8, @splat('x'))), &capture);
    try std.testing.expectError(error.StartupInputOverflow, state.feed("x", &capture));
}
