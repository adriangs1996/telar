//! Preview placement geometry and its committed Kitty output state.

const std = @import("std");
const core = @import("telar-core");
const Io = std.Io;
const schema = core.schema;
const ui = core.ui;
const path_marker = @import("path_marker.zig");
const kitty = @import("../graphics/root.zig").kitty;
const Size = struct { width: u32, height: u32 };

pub const PlacementState = struct {
    id: u32,
    z: i32,
    desired: ?kitty.OutputPlacement = null,
    emitted: ?kitty.OutputPlacement = null,

    pub fn wanted(placement: *const PlacementState) bool {
        return placement.desired != null;
    }

    pub fn damaged(placement: *const PlacementState) bool {
        return !optionalPlacementEql(placement.desired, placement.emitted);
    }

    pub fn write(placement: *PlacementState, writer: *Io.Writer, image_id: u32) Io.Writer.Error!usize {
        if (!placement.damaged()) {
            return 0;
        }

        var written: usize = 0;
        if (placement.emitted != null) {
            written += try kitty.writeDeletePlacement(writer, image_id, placement.id);
        }

        if (placement.desired) |desired| {
            written += try kitty.writeUiPlacement(writer, .{
                .image_id = image_id,
                .placement_id = placement.id,
                .value = desired,
                .z = placement.z,
            });
        }

        placement.emitted = placement.desired;

        return written;
    }
};

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

fn optionalPlacementEql(a: ?kitty.OutputPlacement, b: ?kitty.OutputPlacement) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return std.meta.eql(a.?, b.?);
}
