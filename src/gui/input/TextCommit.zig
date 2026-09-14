//! One owned committed scalar in the bounded input ring. It remains text until
//! the terminal/prompt fallback needs the shared key router.
const Key = @import("telar-client").Key;
const TextInput = @import("TextInput.zig");
const TextCommit = @This();

bytes: [4]u8,
len: u8,
phase: Key.Phase = .press,
physical: ?Key.Physical = null,

/// The returned text borrows this queue entry only during synchronous dispatch.
/// Example: `widget.input(.{ .text = commit.text() });`
pub fn text(commit: *const TextCommit) TextInput {
    return .{ .bytes = commit.bytes[0..commit.len], .phase = commit.phase, .physical = commit.physical };
}

/// Preserves physical ownership and repeats when the shared router is the target.
/// Example: `try router.routeEvent(.{ .key = commit.key(), .raw = "", .now_ns = now }, handler);`
pub fn key(commit: TextCommit) Key {
    return .{ .code = .{ .char = .{ .bytes = commit.bytes, .len = commit.len } }, .phase = commit.phase, .physical = commit.physical };
}
