const InputScanner = @import("../history/InputScanner.zig");
const description = @import("description.zig");
const std = @import("std");
const Capture = @This();

scanner: InputScanner = .{},
bytes: [description.max_query_bytes]u8 = undefined,
len: u16 = 0,
truncated: bool = false,
submitted: bool = false,

/// Returns true exactly once, when the first non-cancelled submit lands.
///
/// ```zig
/// if (capture.feed(input)) {
///     startGeneration(capture.raw());
/// }
/// ```
pub fn feed(self: *Capture, input: []const u8) bool {
    if (self.submitted) {
        return false;
    }
    for (input) |byte| {
        if (self.len < self.bytes.len) {
            self.bytes[self.len] = byte;
            self.len += 1;
        } else {
            self.truncated = true;
        }
        const event = self.scanner.feed(&.{byte});
        if (event.cancelled) {
            self.clear();
            continue;
        }
        if (event.submitted) {
            self.submitted = true;
            return true;
        }
    }
    return false;
}

/// Captures an already submitted composer message without terminal editing semantics.
/// Example: `if (capture.submit("Fix tests\nKeep existing behavior")) queueTitle();`.
pub fn submit(self: *Capture, input: []const u8) bool {
    if (self.submitted or !std.unicode.utf8ValidateSlice(input)) {
        return false;
    }

    self.clear();
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if ((byte < 0x20 and byte != '\r' and byte != '\n' and byte != '\t') or byte == 0x7f) {
            index += 1;
            continue;
        }

        const whitespace = byte == ' ' or byte == '\r' or byte == '\n' or byte == '\t';
        if (whitespace and (self.len == 0 or self.bytes[self.len - 1] == ' ')) {
            index += 1;
            continue;
        }

        const count: usize = if (whitespace) 1 else std.unicode.utf8ByteSequenceLength(byte) catch unreachable;
        if (count > self.bytes.len - self.len) {
            self.truncated = true;
            break;
        }

        if (whitespace) {
            self.bytes[self.len] = ' ';
        } else {
            @memcpy(self.bytes[self.len..][0..count], input[index..][0..count]);
        }
        self.len += @intCast(count);
        index += count;
    }

    if (self.len != 0 and self.bytes[self.len - 1] == ' ') {
        self.bytes[self.len - 1] = 0;
        self.len -= 1;
    }
    self.submitted = true;
    return true;
}

pub fn raw(self: *const Capture) []const u8 {
    return self.bytes[0..self.len];
}

pub fn clear(self: *Capture) void {
    std.crypto.secureZero(u8, self.bytes[0..self.len]);
    self.* = .{};
}

test "submitted composer capture preserves multiline text without terminal edits" {
    var capture: Capture = .{};
    defer capture.clear();
    try std.testing.expect(capture.submit("  Fix\nUTF-8 界\r\n\tand literal a\x08b\x15c\x17d  "));
    try std.testing.expectEqualStrings("Fix UTF-8 界 and literal abcd", capture.raw());
    var normalized: [description.max_query_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &normalized);
    try std.testing.expectEqualStrings(capture.raw(), try description.normalizeQuery(capture.raw(), &normalized));
    try std.testing.expect(!capture.submit("later prompt"));
}

test "submitted composer capture truncates at a UTF-8 boundary and rejects invalid input" {
    var capture: Capture = .{};
    defer capture.clear();
    try std.testing.expect(!capture.submit("broken\xff"));
    try std.testing.expect(!capture.submitted);
    const prefix = "x" ** (description.max_query_bytes - 1);
    try std.testing.expect(capture.submit(prefix ++ "界 tail"));
    try std.testing.expect(capture.truncated);
    try std.testing.expectEqualStrings(prefix, capture.raw());
    try std.testing.expect(std.unicode.utf8ValidateSlice(capture.raw()));
}
