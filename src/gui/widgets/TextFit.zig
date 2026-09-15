//! Fits one label into a pixel width with a trailing ellipsis. Prefix widths
//! come from `Canvas.measure`, so warm labels only read the shaping cache.
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Label = @import("Label.zig");
const TextFit = @This();

pub const ellipsis = "\u{2026}";
pub const max_bytes = 128;

canvas: *Canvas,
width: f32,

/// Returns the label text itself when it fits, otherwise the longest
/// grapheme prefix plus `…` that does, copied into `buffer`.
/// Example: `const text = try fit.fit(label, &buffer);`
pub fn fit(self: TextFit, label: Label, buffer: *[max_bytes]u8) ![]const u8 {
    const full = try self.canvas.measure(label);
    if (full <= self.width) {
        return label.text;
    }

    var probe = label;
    probe.text = ellipsis;
    const tail = try self.canvas.measure(probe);
    if (tail > self.width) {
        return "";
    }

    const room = self.width - tail;
    var keep: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(graphemes(label.text))) * room / full));
    while (keep > 0) : (keep -= 1) {
        const prefix = label.text[0..prefixBytes(label.text, keep)];
        if (prefix.len + ellipsis.len > buffer.len) {
            continue;
        }

        probe.text = prefix;
        if (try self.canvas.measure(probe) <= room) {
            break;
        }
    }

    const prefix = label.text[0..prefixBytes(label.text, keep)];
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len..][0..ellipsis.len], ellipsis);
    return buffer[0 .. prefix.len + ellipsis.len];
}

fn graphemes(text: []const u8) usize {
    var iterator: core.GraphemeIterator = .{ .bytes = text };
    var count: usize = 0;
    while (iterator.next() != null) {
        count += 1;
    }

    return count;
}

fn prefixBytes(text: []const u8, count: usize) usize {
    var iterator: core.GraphemeIterator = .{ .bytes = text };
    var bytes: usize = 0;
    var seen: usize = 0;
    while (seen < count) : (seen += 1) {
        const cluster = iterator.next() orelse break;
        bytes += cluster.bytes.len;
    }

    return bytes;
}
