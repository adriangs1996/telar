const Drawing = @import("Drawing.zig");
const RectType = @import("telar-core").Rect;
const TextType = @import("Text.zig");
const GraphemeIteratorType = @import("telar-core").GraphemeIterator;
const Wrapped = @This();

draw: *Drawing,
area: RectType,
row: u16 = 0,
skip: u32,

pub fn text(wrapped: *Wrapped, value: TextType) void {
    if (wrapped.area.w == 0 or wrapped.row >= wrapped.area.h) {
        return;
    }

    var iterator: GraphemeIteratorType = .{ .bytes = value.text };
    var x: u16 = 0;
    while (iterator.next()) |cluster| {
        const newline = iterator.index > 0 and value.text[iterator.index - 1] == '\n';
        if (newline or @as(u32, x) + cluster.width > wrapped.area.w) {
            if (wrapped.skip > 0) {
                wrapped.skip -= 1;
            } else {
                wrapped.row += 1;
            }

            x = 0;
            if (wrapped.row >= wrapped.area.h) {
                return;
            }

            if (newline) {
                continue;
            }
        }

        if (wrapped.skip == 0) {
            wrapped.draw.line(.{ .x = wrapped.area.x + x, .y = wrapped.area.y + wrapped.row, .w = cluster.width, .h = 1 }, .{ .text = cluster.bytes, .color = value.color });
        }

        x += cluster.width;
    }

    if (wrapped.skip > 0) {
        wrapped.skip -= 1;
    } else {
        wrapped.row += 1;
    }
}
