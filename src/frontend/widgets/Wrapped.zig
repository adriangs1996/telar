const cellgrid = @import("cellgrid");
const Drawing = @import("Drawing.zig");
const Text = @import("Text.zig");
const Wrapped = @This();

draw: *Drawing,
area: cellgrid.Rect,
row: u16 = 0,
skip: u32,

pub fn text(self: *Wrapped, value: Text) void {
    if (self.area.w == 0 or self.row >= self.area.h) {
        return;
    }

    var iterator: cellgrid.GraphemeIterator = .{ .bytes = value.text };
    var x: u16 = 0;
    while (iterator.next()) |cluster| {
        const newline = iterator.index > 0 and value.text[iterator.index - 1] == '\n';
        if (newline or @as(u32, x) + cluster.width > self.area.w) {
            if (self.skip > 0) {
                self.skip -= 1;
            } else {
                self.row += 1;
            }

            x = 0;
            if (self.row >= self.area.h) {
                return;
            }

            if (newline) {
                continue;
            }
        }

        if (self.skip == 0) {
            self.draw.line(.{ .x = self.area.x + x, .y = self.area.y + self.row, .w = cluster.width, .h = 1 }, .{ .text = cluster.bytes, .color = value.color });
        }

        x += cluster.width;
    }

    if (self.skip > 0) {
        self.skip -= 1;
    } else {
        self.row += 1;
    }
}
