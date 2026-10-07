//! Live child-process and PTY ownership for one runtime pane.

const Size = @import("Size.zig");
const std = @import("std");

pub fn windowSize(requested: Size) std.posix.winsize {
    const size = requested.valid();
    return .{
        .row = size.rows,
        .col = size.cols,
        .xpixel = std.math.mul(u16, size.cols, size.cell_width_px) catch std.math.maxInt(u16),
        .ypixel = std.math.mul(u16, size.rows, size.cell_height_px) catch std.math.maxInt(u16),
    };
}
