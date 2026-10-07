//! One bounded line naming what an agent last did or asks for. The runtime
//! truncates on a UTF-8 boundary and drops the text at its first control
//! byte, so the stored line is always valid for the wire.

const core = @import("telar-core");
const std = @import("std");
const EventLine = @This();

// SAFETY: set copies the bounded valid line before setting len; text readers use only that prefix.
bytes: [core.max_agent_last_event_bytes]u8 = undefined,
len: u8 = 0,

/// Stores the first control-free line of `text`, cut to the wire bound on
/// a UTF-8 boundary.
///
/// ```zig
/// const line = EventLine.init("» Edit src/proxy.zig\nmore");
/// ```
pub fn init(text: []const u8) EventLine {
    var line: EventLine = .{};
    line.set(text);
    return line;
}

/// Replaces the stored line with the first control-free line of `text`.
///
/// ```zig
/// line.set("Run zig build test?");
/// ```
pub fn set(self: *EventLine, text: []const u8) void {
    var end: usize = 0;
    while (end < text.len and end < self.bytes.len and text[end] >= 0x20 and text[end] != 0x7f) {
        end += 1;
    }

    while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) {
        end -= 1;
    }

    if (!std.unicode.utf8ValidateSlice(text[0..end])) {
        end = 0;
    }

    @memcpy(self.bytes[0..end], text[0..end]);
    self.len = @intCast(end);
}

/// Borrows the stored line.
///
/// ```zig
/// entry.last_event = line.slice();
/// ```
pub fn slice(self: *const EventLine) []const u8 {
    return self.bytes[0..self.len];
}

/// Reports whether two lines carry the same bytes.
///
/// ```zig
/// if (!previous.eql(&current)) bumpRevision();
/// ```
pub fn eql(self: *const EventLine, other: *const EventLine) bool {
    return std.mem.eql(u8, self.slice(), other.slice());
}
