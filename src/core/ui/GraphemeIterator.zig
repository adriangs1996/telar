const ClusterType = @import("Cluster.zig");
const unicode = @import("unicode");
const std = @import("std");
const text = @import("text.zig");
/// Splits text into grapheme clusters and reports each one's column width.
///
/// The segmentation is not ours: `unicode.graphemeWidth` consumes a codepoint
/// slice and reports how many codepoints the first cluster spans and how many
/// columns it occupies. Which table answers is a build-time choice, and the
/// default is the emulator's own - herdr draws its chrome next to panes that
/// same emulator laid out, and two disagreeing width tables produce a UI that
/// drifts one column at a time.
const GraphemeIterator = @This();

bytes: []const u8,
index: usize = 0,

/// Long enough for a base character with combining marks or an emoji
/// sequence with a couple of joiners. A cluster longer than this is split,
/// which costs a rendering artefact and never a wrong byte count.
const window = 16;

pub const Cluster = @import("Cluster.zig");

pub fn next(it: *GraphemeIterator) ?ClusterType {
    if (it.index >= it.bytes.len) {
        return null;
    }

    // Almost every chrome string is ASCII. A printable ASCII byte that is
    // not followed by a multi-byte sequence cannot join a cluster (only a
    // combining mark, joiner or selector could, and those start above
    // 0x7f), so its cluster is known without decoding a window. The width
    // still comes from the table: the drawing core never assumes one.
    const first = it.bytes[it.index];
    if (first >= 0x20 and first < 0x7f and
        (it.index + 1 == it.bytes.len or it.bytes[it.index + 1] < 0x80))
    {
        const start = it.index;
        it.index += 1;
        const single = [_]u21{first};
        const measured = unicode.graphemeWidth(&single);
        return .{
            .bytes = it.bytes[start..it.index],
            .width = if (measured.width == 0) 1 else @intCast(measured.width),
        };
    }

    // Decode a window, remembering where each codepoint began so the
    // cluster's byte length can be recovered from its codepoint length.
    var codepoints: [window]u21 = undefined;
    var offsets: [window + 1]usize = undefined;
    var count: usize = 0;
    var cursor = it.index;
    offsets[0] = cursor;

    while (count < window and cursor < it.bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(it.bytes[cursor]) catch break;
        if (cursor + length > it.bytes.len) {
            break;
        }
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
    if (text.isControl(codepoints[0])) {
        return .{ .bytes = " ", .width = 1 };
    }

    return .{
        .bytes = it.bytes[start..it.index],
        // Control characters measure zero, and a zero width cell cannot be
        // addressed. Anything unprintable becomes one blank column.
        .width = if (measured.width == 0) 1 else @intCast(measured.width),
    };
}
