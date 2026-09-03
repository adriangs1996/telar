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

/// Splits text into grapheme clusters and reports each one's column width.
///
/// The segmentation is not ours: `unicode.graphemeWidth` consumes a codepoint
/// slice and reports how many codepoints the first cluster spans and how many
/// columns it occupies. Which table answers is a build-time choice, and the
/// default is the emulator's own - herdr draws its chrome next to panes that
/// same emulator laid out, and two disagreeing width tables produce a UI that
/// drifts one column at a time.
pub const GraphemeIterator = struct {
    bytes: []const u8,
    index: usize = 0,

    /// Long enough for a base character with combining marks or an emoji
    /// sequence with a couple of joiners. A cluster longer than this is split,
    /// which costs a rendering artefact and never a wrong byte count.
    const window = 16;

    pub const Cluster = struct {
        bytes: []const u8,
        width: u8,
    };

    pub fn next(it: *GraphemeIterator) ?Cluster {
        if (it.index >= it.bytes.len) return null;

        // Decode a window, remembering where each codepoint began so the
        // cluster's byte length can be recovered from its codepoint length.
        var codepoints: [window]u21 = undefined;
        var offsets: [window + 1]usize = undefined;
        var count: usize = 0;
        var cursor = it.index;
        offsets[0] = cursor;

        while (count < window and cursor < it.bytes.len) {
            const length = std.unicode.utf8ByteSequenceLength(it.bytes[cursor]) catch break;
            if (cursor + length > it.bytes.len) break;
            const codepoint = std.unicode.utf8Decode(it.bytes[cursor..][0..length]) catch break;
            codepoints[count] = codepoint;
            count += 1;
            cursor += length;
            offsets[count] = cursor;
        }

        if (count == 0) {
            // Invalid or truncated UTF-8. Agents print partial writes, so this
            // is a cell to draw, not an error to propagate.
            it.index += 1;
            return .{ .bytes = "\u{FFFD}", .width = 1 };
        }

        const measured = unicode.graphemeWidth(codepoints[0..count]);
        const start = it.index;
        it.index = offsets[measured.len];

        // A control character never reaches a cell as itself. The screen diff
        // writes cell text verbatim, so a raw newline or escape in a cell
        // moves the host cursor and every cell after it lands on the wrong
        // row. It still owns one column, drawn blank.
        if (isControl(codepoints[0])) {
            return .{ .bytes = " ", .width = 1 };
        }

        return .{
            .bytes = it.bytes[start..it.index],
            // Control characters measure zero, and a zero width cell cannot be
            // addressed. Anything unprintable becomes one blank column.
            .width = if (measured.width == 0) 1 else @intCast(measured.width),
        };
    }
};

/// C0 controls, DEL and C1 controls: the codepoints a terminal interprets
/// instead of drawing.
fn isControl(codepoint: u21) bool {
    return codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

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
            if (guard > sample.len + 1) return error.DidNotTerminate;
        }
    }
}
