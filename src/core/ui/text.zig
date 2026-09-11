//! How many columns a string occupies.
//!
//! The question that quietly sinks hand rolled terminal UIs, and the reason it
//! is a file of its own: the answer must come from one place, because a
//! measurement and a draw that consult different tables disagree by one column
//! and keep going.
//!
//! Which table answers is a build-time choice. The default is the emulator that
//! renders the agents' own output, since that is the only answer guaranteed to
//! match what appears on screen.

const std = @import("std");
/// Imported by module name rather than by path so that a build can swap the
/// width tables out. See `unicode.zig`.
const unicode = @import("unicode");

pub fn measure(text: []const u8) u16 {
    var total: u16 = 0;
    var it: GraphemeIterator = .{ .bytes = text };
    while (it.next()) |cluster| total += cluster.width;
    return total;
}

pub const GraphemeIterator = @import("GraphemeIterator.zig");

/// C0 controls, DEL and C1 controls: the codepoints a terminal interprets
/// instead of drawing.
pub fn isControl(codepoint: u21) bool {
    return codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "printable ascii measures one column with or without the fast path" {
    var it: GraphemeIterator = .{ .bytes = "ab\u{0301}c" };
    // 'a' takes the fast path; 'b' is followed by a combining acute and must
    // go through the table so the mark stays attached.
    const a = it.next().?;
    try testing.expectEqualStrings("a", a.bytes);
    try testing.expectEqual(@as(u8, 1), a.width);
    const b = it.next().?;
    try testing.expectEqualStrings("b\u{0301}", b.bytes);
    try testing.expectEqual(@as(u8, 1), b.width);
    const c = it.next().?;
    try testing.expectEqualStrings("c", c.bytes);
    try testing.expect(it.next() == null);
}

test "a control character becomes a blank cell rather than its own byte" {
    // The diff emits cell text unchanged. A newline stored in a cell would
    // move the real cursor and smear every later cell of the frame.
    const samples = [_][]const u8{ "\n", "\r", "\x1b", "\x7f", "\u{0085}" };
    for (samples) |sample| {
        var it: GraphemeIterator = .{ .bytes = sample };
        const cluster = it.next().?;
        try testing.expectEqualStrings(" ", cluster.bytes);
        try testing.expectEqual(@as(u8, 1), cluster.width);
        try testing.expectEqual(@as(?GraphemeIterator.Cluster, null), it.next());
    }

    var it: GraphemeIterator = .{ .bytes = "a\nb" };
    try testing.expectEqualStrings("a", it.next().?.bytes);
    try testing.expectEqualStrings(" ", it.next().?.bytes);
    try testing.expectEqualStrings("b", it.next().?.bytes);
}

test "measuring and iterating cannot disagree" {
    // They share the iterator on purpose. Right alignment and truncation both
    // depend on the two answering identically, and a separate width function -
    // however carefully written - is a second source of truth that drifts.
    const samples = [_][]const u8{
        "plain",
        "caf\u{00e9}",
        "cafe\u{0301}", // the same word, decomposed
        "\u{6f22}\u{5b57}", // two columns each
        "\u{1F468}\u{200D}\u{1F680}", // one cluster, four codepoints
        "",
    };
    for (samples) |sample| {
        var total: u16 = 0;
        var it: GraphemeIterator = .{ .bytes = sample };
        while (it.next()) |cluster| total += cluster.width;
        try testing.expectEqual(total, measure(sample));
    }
}

test "a composed and a decomposed word measure the same" {
    // Three bytes apart, one column apart if this is wrong - and the drift is
    // invisible until a name happens to carry an accent.
    try testing.expectEqual(measure("caf\u{00e9}"), measure("cafe\u{0301}"));
    try testing.expectEqual(@as(u16, 4), measure("cafe\u{0301}"));
}

test "a wide glyph is two columns and one cluster" {
    var it: GraphemeIterator = .{ .bytes = "\u{6f22}" };
    const cluster = it.next().?;
    try testing.expectEqual(@as(u8, 2), cluster.width);
    try testing.expectEqualStrings("\u{6f22}", cluster.bytes);
    try testing.expectEqual(@as(?GraphemeIterator.Cluster, null), it.next());
}

test "an unprintable character still occupies a column" {
    // A zero width cell cannot be addressed by a cursor, so anything the tables
    // measure as nothing becomes one blank rather than a hole the layout would
    // silently close up.
    try testing.expectEqual(@as(u16, 1), measure("\x01"));
}

test "invalid utf-8 measures as one column rather than failing" {
    // Agents produce partial writes. A lone continuation byte is a cell to
    // draw, not an error to propagate up through the layout.
    try testing.expectEqual(@as(u16, 1), measure("\xff"));

    var it: GraphemeIterator = .{ .bytes = "\xffa" };
    try testing.expectEqualStrings("\u{FFFD}", it.next().?.bytes);
    try testing.expectEqualStrings("a", it.next().?.bytes);
}

test "iteration terminates on every prefix of a multi byte sequence" {
    // The iterator is fed slices that end mid character all the time, because
    // that is what a terminal read looks like. Any prefix that failed to
    // advance would hang the draw.
    const sample = "a\u{00e9}\u{6f22}\u{1F680}b";
    var length: usize = 0;
    while (length <= sample.len) : (length += 1) {
        var it: GraphemeIterator = .{ .bytes = sample[0..length] };
        var guard: usize = 0;
        while (it.next()) |_| {
            guard += 1;
            if (guard > sample.len + 1) {
                return error.DidNotTerminate;
            }
        }
    }
}
