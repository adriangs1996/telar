//! The reason a configuration, Lua callback, bar, panel, pick or action
//! failed, in a fixed buffer. A message longer than the buffer keeps its
//! start, cut at a character, and ends with `truncation_mark`.
const bar_text = @import("../bars/bar_text.zig");
const std = @import("std");
const Diagnostic = @This();

pub const max_bytes = 1024;
/// Ends a message that did not fit, so a cut never reads as complete.
pub const truncation_mark = "…";

// SAFETY: set publishes only bytes written by the formatter, plus an initialized truncation mark on overflow; message is bounded by len.
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
