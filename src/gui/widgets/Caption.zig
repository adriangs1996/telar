//! Proportional text in bounded shaping runs, including long diagnostics.
const core = @import("telar-core");
const std = @import("std");
const Canvas = @import("Canvas.zig");
const Caption = @This();

bounds: @import("../render/Rect.zig"),
label: @import("Label.zig"),

/// Word boundaries keep ordinary shaping intact while every run fits the
/// existing cache. Only visible runs are painted; no storage is retained.
/// Example: `try (Caption{ .bounds = area, .label = label }).draw(canvas);`
pub fn draw(caption: Caption, canvas: *Canvas) !void {
    var remaining = caption.bounds;
    var iterator: core.GraphemeIterator = .{ .bytes = caption.label.text };
    while (remaining.width > 0 and iterator.index < iterator.bytes.len) {
        var storage: [64]u8 = undefined;
        var len: usize = 0;
        var count: usize = 0;
        var break_len: usize = 0;
        var word_end = iterator;
        while (iterator.index < iterator.bytes.len) {
            const before = iterator;
            const cluster = iterator.next() orelse break;
            const codepoints = std.unicode.utf8CountCodepoints(cluster.bytes) catch unreachable;
            if (len + cluster.bytes.len > 64 or count + codepoints > 30) {
                if (len == 0) {
                    const replacement = "�";
                    @memcpy(storage[0..replacement.len], replacement);
                    len = replacement.len;
                } else {
                    iterator = before;
                }

                break;
            }

            @memcpy(storage[len..][0..cluster.bytes.len], cluster.bytes);
            len += cluster.bytes.len;
            count += codepoints;
            if (std.mem.eql(u8, cluster.bytes, " ")) {
                word_end = iterator;
                break_len = len;
            }
        }

        if (iterator.index < iterator.bytes.len and break_len != 0) {
            iterator = word_end;
            len = break_len;
        }

        var label = caption.label;
        label.text = storage[0..len];
        const width = try canvas.textAt(remaining, label);
        if (width <= 0) {
            break;
        }

        remaining.x += width;
        remaining.width = @max(0, remaining.width - width);
    }
}
