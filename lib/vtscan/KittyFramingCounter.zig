//! Counts complete Kitty graphics commands across arbitrary PTY read
//! boundaries without retaining their payload, and tells whether a read
//! touches one. Ghostty performs the actual parsing; this recognizer frames
//! commands the way it does (`ApcFraming`) so the media actor can bound the
//! chunks of an incomplete upload and the runtime can tell graphics output
//! from text.
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
