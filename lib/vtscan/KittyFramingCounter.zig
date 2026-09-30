//! Counts complete Kitty graphics commands across arbitrary PTY read
//! boundaries without retaining their payload, and tells whether a read
//! touches one. Ghostty performs the actual parsing; this recognizer frames
//! commands the way it does (`ApcFraming`) so the media actor can bound the
//! chunks of an incomplete upload and the runtime can tell graphics output
//! from text.
const std = @import("std");
const ApcFraming = @import("ApcFraming.zig");
const KittyFramingCounter = @This();

framing: ApcFraming = .{},

/// Whether the last byte observed left the scanner inside a Kitty command.
/// Example: `if (counter.inKitty()) pause();`.
pub fn inKitty(self: *const KittyFramingCounter) bool {
    return self.framing.inKitty();
}

/// Advances over `bytes` like `observe` and reports whether any of them
/// belongs to a Kitty command, introducer and terminator included.
/// Example: `const graphics = counter.touchesKitty(read);`.
pub fn touchesKitty(self: *KittyFramingCounter, bytes: []const u8) bool {
    var touched = self.inKitty();
    var index: usize = 0;
    while (self.framing.advance(bytes, &index)) |_| {
        touched = true;
    }

    return touched;
}

/// Advances over `bytes` and returns how many Kitty commands ended in them.
/// Example: `const complete = counter.observe(read);`.
pub fn observe(self: *KittyFramingCounter, bytes: []const u8) usize {
    var complete: usize = 0;
    var index: usize = 0;
    while (self.framing.advance(bytes, &index)) |transition| {
        complete += @intFromBool(transition == .kitty_ended);
    }

    return complete;
}

test "kitty APC bytes are recognized across reads while plain output is not" {
    var counter: KittyFramingCounter = .{};
    try std.testing.expect(!counter.touchesKitty("plain text \x1b[1m bold"));
    try std.testing.expect(!counter.touchesKitty("\x1b_Xother\x1b\\"));
    try std.testing.expect(counter.touchesKitty("text \x1b_Ga=T,f=100;AAAA"));
    try std.testing.expect(counter.inKitty());
    try std.testing.expect(counter.touchesKitty("BBBB"));
    try std.testing.expect(counter.touchesKitty("CC\x1b"));
    try std.testing.expect(!counter.inKitty());
    try std.testing.expect(!counter.touchesKitty("\\ after"));
}

test "an APC introducer split after its ESC is still recognized" {
    var counter: KittyFramingCounter = .{};
    try std.testing.expect(!counter.touchesKitty("colored \x1b[32mtext\x1b[0m \x1b"));
    try std.testing.expect(counter.touchesKitty("_Ga=T,f=100;AAAA\x1b\\"));
    try std.testing.expect(!counter.inKitty());
    try std.testing.expect(!counter.touchesKitty("snake_case names_and \x1b_Xnot kitty\x1b\\ more_text"));
}

test "an interrupted upload stops holding at the next escape" {
    var counter: KittyFramingCounter = .{};
    try std.testing.expect(counter.touchesKitty("\x1b_Ga=T,f=100,m=1;iVBORw0KGgo"));
    try std.testing.expect(counter.inKitty());
    try std.testing.expectEqual(@as(usize, 1), counter.observe("^C\r\n\x1b[32m$ "));
    try std.testing.expect(!counter.inKitty());
}
