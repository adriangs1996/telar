//! One owned committed scalar in the bounded input ring. It remains text until
//! the terminal/prompt fallback needs the shared key router.
const data = @import("model");
const TextInput = @import("TextInput.zig");
const TextCommit = @This();

bytes: [4]u8,
len: u8,
phase: data.Key.Phase = .press,
physical: ?data.Key.Physical = null,

/// The returned text borrows this queue entry only during synchronous dispatch.
/// Example: `widget.input(.{ .text = commit.text() });`
pub fn text(self: *const TextCommit) TextInput {
    return .{ .bytes = self.bytes[0..self.len], .phase = self.phase, .physical = self.physical };
}

/// Preserves physical ownership and repeats when the shared router is the target.
/// Example: `_ = try gui.routeKey(.{ .key = commit.key(), .raw = "", .now_ns = now });`
pub fn key(self: TextCommit) data.Key {
    return .{ .code = .{ .char = .{ .bytes = self.bytes, .len = self.len } }, .phase = self.phase, .physical = self.physical };
}
