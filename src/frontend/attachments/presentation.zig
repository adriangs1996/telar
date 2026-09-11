//! Preview placement geometry and its committed Kitty output state.

const std = @import("std");
const core = @import("telar-core");
pub const Io = std.Io;
const schema = core.schema;
const ui = core.ui;
const path_marker = @import("telar-client").attachments.path_marker;
const kitty = @import("../graphics/root.zig").kitty;
const Size = @import("Size.zig");

pub const PlacementState = @import("PlacementState.zig");

/// Example: `const placement = fitPlacement(image_size, cell_size, area);`.
pub fn fitPlacement(image: Size, cell: Size, area: ui.Rect) ?kitty.OutputPlacement {
    if (area.isEmpty()) {
        return null;
    }
    const max_width_px = @as(u64, area.w) * cell.width;
    const max_height_px = @as(u64, area.h) * cell.height;
    var columns: u64 = area.w;
    const height_at_full_width = std.math.divCeil(
        u64,
        max_width_px * image.height,
        image.width,
    ) catch return null;
    var rows = std.math.divCeil(u64, height_at_full_width, cell.height) catch return null;
    if (rows > area.h) {
        rows = area.h;
        const width_at_full_height = std.math.divCeil(
            u64,
            max_height_px * image.width,
            image.height,
        ) catch return null;
        columns = std.math.divCeil(u64, width_at_full_height, cell.width) catch return null;
    }
    columns = std.math.clamp(columns, 1, area.w);
    rows = std.math.clamp(rows, 1, area.h);
    return .{
        .column = area.x + @as(u16, @intCast((area.w - columns) / 2)),
        .row = area.y + @as(u16, @intCast((area.h - rows) / 2)),
        .offset_x = 0,
        .offset_y = 0,
        .source_x = 0,
        .source_y = 0,
        .source_width = image.width,
        .source_height = image.height,
        .columns = @intCast(columns),
        .rows = @intCast(rows),
    };
}

pub fn optionalPlacementEql(a: ?kitty.OutputPlacement, b: ?kitty.OutputPlacement) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return std.meta.eql(a.?, b.?);
}
