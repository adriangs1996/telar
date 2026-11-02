const gfx = @import("gfx");
const cellgrid = @import("cellgrid");
const Label = @import("Label.zig");
const record_geometry = @import("record_geometry.zig");
const Canvas = @This();

const Chrome = struct {
    ratio: f32 = 1,
    pub fn px(self: Chrome, value: f32) f32 {
        return value * self.ratio;
    }
};
const Palette = struct { accent: cellgrid.Color = .{}, surface_dim: cellgrid.Color = .{}, surface0: cellgrid.Color = .{}, surface1: cellgrid.Color = .{}, text: cellgrid.Color = .{}, subtext0: cellgrid.Color = .{}, yellow: cellgrid.Color = .{} };
chrome: Chrome = .{},
theme: struct { palette: Palette = .{} } = .{},
advances: [17]f32 = @splat(0),
more: f32 = 0,
fold: f32 = 0,

pub fn measure(self: *Canvas, label: Label) !f32 {
    if (label.text.len > 0 and label.text[0] == '+') {
        return if (label.text.len == 3 and label.text[1] == '9') self.more else self.fold;
    }

    const radix = 10;
    const slot: usize = @as(usize, label.text[1] - '0') * radix + label.text[2] - '0';

    return self.advances[slot];
}

pub fn textAt(self: *Canvas, area: gfx.Rect, label: Label) !bool {
    _ = self;
    _ = label;
    try record_geometry.rectangle(.text, area);

    return true;
}

pub fn fillRoundedAt(self: *Canvas, area: gfx.Rect, fill: struct { radius: f32, color: cellgrid.Color }) !void {
    _ = self;
    _ = fill;
    try record_geometry.rectangle(.fill, area);
}
