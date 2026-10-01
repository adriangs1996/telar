//! The reason a configuration, Lua callback, bar, panel, pick or action
//! failed, in a fixed buffer. A message longer than the buffer keeps its
//! start, cut at a character, and ends with `truncation_mark`.
const bar_text = @import("../bars/bar_text.zig");
const std = @import("std");
const Diagnostic = @This();

pub const max_bytes = 1024;
/// Ends a message that did not fit, so a cut never reads as complete.
pub const truncation_mark = "…";

buffer: [max_bytes]u8 = undefined,
len: usize = 0,

pub fn message(self: *const Diagnostic) []const u8 {
    return self.buffer[0..self.len];
}

/// Formats the message; one longer than `max_bytes` keeps what fits.
///
/// ```zig
/// diagnostic.set("unknown action kind '{s}'", .{kind});
/// ```
pub fn set(self: *Diagnostic, comptime format: []const u8, args: anytype) void {
    var writer: std.Io.Writer = .fixed(&self.buffer);
    writer.print(format, args) catch {
        const kept = bar_text.prefix(writer.buffered(), max_bytes - truncation_mark.len);
        @memcpy(self.buffer[kept.len..][0..truncation_mark.len], truncation_mark);
        self.len = kept.len + truncation_mark.len;
        return;
    };

    self.len = writer.buffered().len;
}

test "a message past the buffer keeps its start, cut at a character, and ends with the mark" {
    var diagnostic: Diagnostic = .{};
    diagnostic.set("error in {s}", .{"é" ** max_bytes});

    const text = diagnostic.message();
    try std.testing.expect(text.len <= max_bytes);
    try std.testing.expect(std.mem.startsWith(u8, text, "error in éé"));
    try std.testing.expect(std.mem.endsWith(u8, text, truncation_mark));
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));

    diagnostic.set("{s}", .{"x" ** max_bytes});
    try std.testing.expectEqualStrings("x" ** max_bytes, diagnostic.message());
}
