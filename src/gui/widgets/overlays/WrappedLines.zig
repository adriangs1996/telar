const cellgrid = @import("cellgrid");
const std = @import("std");
const WrappedLines = @This();

text: []const u8,
width: u16,
/// Break at the last space that fits rather than inside a word; a word
/// longer than a line still splits. Commands read better this way, while
/// captured output keeps the terminal's exact wrapping.
words: bool = false,
index: usize = 0,
finished: bool = false,

/// Borrows one complete visible line, splitting only at grapheme boundaries.
/// Canvas sanitizes control characters before creating glyphs.
/// Example: `while (lines.next()) |line| try canvas.text(area, label(line));`.
pub fn next(self: *WrappedLines) ?[]const u8 {
    if (self.finished or self.width == 0) {
        return null;
    }

    const start = self.index;
    var used: u16 = 0;
    // Where the line may end: after the last space it holds.
    var word_start = start;
    var iterator: cellgrid.GraphemeIterator = .{ .bytes = self.text, .index = self.index };
    while (iterator.index < self.text.len) {
        const before = iterator.index;
        if (self.text[before] == '\n' or self.text[before] == '\r') {
            self.index = before + 1;
            if (self.text[before] == '\r' and self.index < self.text.len and self.text[self.index] == '\n') {
                self.index += 1;
            }

            return self.text[start..before];
        }

        const cluster = iterator.next().?;
        if (@as(u32, used) + cluster.width > self.width) {
            self.index = if (used == 0) iterator.index else if (self.words and word_start > start) word_start else before;
            self.finished = self.index == self.text.len;
            return self.text[start..self.index];
        }

        used += cluster.width;
        if (self.words and cluster.bytes.len == 1 and cluster.bytes[0] == ' ') {
            word_start = iterator.index;
        }
    }

    self.index = self.text.len;
    self.finished = true;
    return self.text[start..];
}

/// Counts with the exact same wrapping used for painting.
/// Example: `const maximum_scroll = lines.count() -| visible_rows;`.
pub fn count(self: WrappedLines) u32 {
    var copy = self;
    var total: u32 = 0;
    while (copy.next() != null) {
        total += 1;
    }

    return total;
}

test "word wrapping ends a line at its last space and still splits a long word" {
    var lines: WrappedLines = .{ .text = "zig build test-gui --summary all", .width = 12, .words = true };
    try std.testing.expectEqualStrings("zig build ", lines.next().?);
    try std.testing.expectEqualStrings("test-gui ", lines.next().?);
    try std.testing.expectEqualStrings("--summary ", lines.next().?);
    try std.testing.expectEqualStrings("all", lines.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());

    var long: WrappedLines = .{ .text = "echo aaaaaaaaaaaaaaaa b", .width = 8, .words = true };
    try std.testing.expectEqualStrings("echo ", long.next().?);
    try std.testing.expectEqualStrings("aaaaaaaa", long.next().?);
    try std.testing.expectEqualStrings("aaaaaaaa", long.next().?);
    try std.testing.expectEqualStrings(" b", long.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), long.next());

    // Every byte lands on exactly one line, in order, and counting agrees.
    const text = "for 界 in 日本語 e\u{301}e\u{301}; do\n  echo \"$word\"\ndone";
    var joined: [128]u8 = undefined;
    var len: usize = 0;
    var all: WrappedLines = .{ .text = text, .width = 7, .words = true };
    const count_before = all.count();
    var seen: u32 = 0;
    while (all.next()) |line| {
        @memcpy(joined[len..][0..line.len], line);
        len += line.len;
        seen += 1;
    }

    try std.testing.expectEqual(count_before, seen);
    var expected: [128]u8 = undefined;
    const stripped = std.mem.replace(u8, text, "\n", "", &expected);
    try std.testing.expectEqualStrings(expected[0 .. text.len - stripped], joined[0..len]);
}
