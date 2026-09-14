//! One bounded line naming what an agent last did or asks for. The runtime
//! truncates on a UTF-8 boundary and drops the text at its first control
//! byte, so the stored line is always valid for the wire.

const max_agent_last_event_bytes_module = @import("telar-core").max_agent_last_event_bytes;
const std = @import("std");
const EventLine = @This();

bytes: [max_agent_last_event_bytes_module]u8 = undefined,
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
pub fn set(line: *EventLine, text: []const u8) void {
    var end: usize = 0;
    while (end < text.len and end < line.bytes.len and text[end] >= 0x20 and text[end] != 0x7f) {
        end += 1;
    }

    while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) {
        end -= 1;
    }

    if (!std.unicode.utf8ValidateSlice(text[0..end])) {
        end = 0;
    }

    @memcpy(line.bytes[0..end], text[0..end]);
    line.len = @intCast(end);
}

/// Borrows the stored line.
///
/// ```zig
/// entry.last_event = line.slice();
/// ```
pub fn slice(line: *const EventLine) []const u8 {
    return line.bytes[0..line.len];
}

/// Reports whether two lines carry the same bytes.
///
/// ```zig
/// if (!previous.eql(&current)) bumpRevision();
/// ```
pub fn eql(line: *const EventLine, other: *const EventLine) bool {
    return std.mem.eql(u8, line.slice(), other.slice());
}

test "event lines keep one control-free UTF-8 line within the wire bound" {
    try std.testing.expectEqualStrings("» Edit src/proxy.zig", init("» Edit src/proxy.zig\nsecond").slice());
    try std.testing.expectEqualStrings("tab", init("tab\tcut").slice());

    const long = "é" ** 60;
    const cut = init(long);
    try std.testing.expectEqual(@as(u8, 96), cut.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut.slice()));

    try std.testing.expectEqual(@as(u8, 0), init("\xff\xfe").len);
    try std.testing.expect(init("same").eql(&init("same\n")));
    try std.testing.expect(!init("same").eql(&init("other")));
}
