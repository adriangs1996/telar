const std = @import("std");
const escape_ops = @import("escape.zig");
/// Counts complete Kitty APC commands across arbitrary PTY read boundaries
/// without retaining their payload. Ghostty performs the actual parsing; this
/// recognizer exists only to enforce a bounded number of chunks in an
/// incomplete upload.
///
/// Only ESC-introduced sequences count. The emulator parses the stream as
/// UTF-8, where the raw C1 bytes 0x9f (APC) and 0x9c (ST) are ordinary
/// continuation bytes; honouring them here would let plain text ("ß" is
/// 0xC3 0x9F) desynchronize the chunk count.
const KittyFramingCounter = @This();

state: State = .normal,

const State = enum { normal, escape, apc_identify, kitty, kitty_escape, other, other_escape };

/// Whether the last byte observed left the scanner inside a Kitty APC.
/// Example: `if (counter.inKitty()) pause();`.
pub fn inKitty(self: *const KittyFramingCounter) bool {
    return self.state == .kitty or self.state == .kitty_escape;
}

/// Advances over `bytes` like `observe` and reports whether any of them
/// belongs to a Kitty APC, introducer and terminator included. Runs of
/// bytes that cannot change the state are skipped with a vector search for
/// ESC, so plain output costs one scan.
/// Example: `const graphics = counter.touchesKitty(read);`.
pub fn touchesKitty(self: *KittyFramingCounter, bytes: []const u8) bool {
    var touched = self.inKitty();
    var rest = bytes;
    while (rest.len != 0) {
        switch (self.state) {
            .normal, .escape => {
                const start = escape_ops.findApc(rest, 0, self.state == .escape) orelse {
                    self.state = if (rest[rest.len - 1] == escape_ops.esc) .escape else .normal;
                    return touched;
                };
                self.state = .apc_identify;
                rest = rest[start..];
                continue;
            },
            .kitty, .other => {
                const at = std.mem.indexOfScalar(u8, rest, escape_ops.esc) orelse return touched;
                rest = rest[at..];
            },
            else => {},
        }

        const before = self.state;
        _ = self.observe(rest[0..1]);
        touched = touched or self.inKitty() or before == .kitty_escape;
        rest = rest[1..];
    }

    return touched;
}

pub fn observe(self: *KittyFramingCounter, bytes: []const u8) usize {
    var complete: usize = 0;
    for (bytes) |byte| switch (self.state) {
        .normal => self.state = if (byte == escape_ops.esc) .escape else .normal,
        .escape => self.state = switch (byte) {
            '_' => .apc_identify,
            escape_ops.esc => .escape,
            else => .normal,
        },
        .apc_identify => self.state = if (byte == 'G')
            .kitty
        else if (byte == escape_ops.esc)
            .other_escape
        else
            .other,
        .kitty => self.state = switch (byte) {
            escape_ops.esc => .kitty_escape,
            else => .kitty,
        },
        .kitty_escape => self.state = if (byte == '\\') state: {
            complete += 1;
            break :state .normal;
        } else if (byte == escape_ops.esc)
            .kitty_escape
        else
            .kitty,
        .other => self.state = switch (byte) {
            escape_ops.esc => .other_escape,
            else => .other,
        },
        .other_escape => self.state = if (byte == '\\')
            .normal
        else if (byte == escape_ops.esc)
            .other_escape
        else
            .other,
    };
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
    try std.testing.expect(counter.touchesKitty("\\ after"));
    try std.testing.expect(!counter.inKitty());
    try std.testing.expect(!counter.touchesKitty("after"));
}

test "an APC introducer split after its ESC is still recognized" {
    var counter: KittyFramingCounter = .{};
    try std.testing.expect(!counter.touchesKitty("colored \x1b[32mtext\x1b[0m \x1b"));
    try std.testing.expect(counter.touchesKitty("_Ga=T,f=100;AAAA\x1b\\"));
    try std.testing.expect(!counter.inKitty());
    try std.testing.expect(!counter.touchesKitty("snake_case names_and \x1b_Xnot kitty\x1b\\ more_text"));
}
