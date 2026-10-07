//! Resolves a placement's drawn size and layer the way kitty and Ghostty
//! draw classic placements.

const std = @import("std");
const DisplayBox = @import("DisplayBox.zig");
const DisplayCells = @import("DisplayCells.zig");
const DisplayRequest = @import("DisplayRequest.zig");
const Layer = @import("Layer.zig").Layer;

/// "Negative z-index values below INT32_MIN/2 (-1,073,741,824) will be drawn
/// under cells with non-default background colors." The boundary itself
/// draws over backgrounds, as in kitty and Ghostty.
pub const below_background_limit: i32 = std.math.minInt(i32) / 2;

/// Resolves the drawn box of one placement:
///
/// - no columns and no rows: the source rectangle at its natural pixel size;
/// - columns and rows: stretched to fill them, less the offset (kitty and
///   Ghostty stretch; the spec's letterbox sentence of 2026-08-23 is not
///   what either renderer does);
/// - only one of them: that side fills its cells less the offset, the other
///   follows the source aspect ratio, rounded to the nearest pixel.
///
/// Offsets are clamped inside the cell ("the offsets must be smaller than the
/// size of the cell").
///
/// ```zig
/// const box = display.box(.{ .source_width = 640, .source_height = 480, .columns = 20, .cell_width = 16, .cell_height = 32 });
/// ```
pub fn box(request: DisplayRequest) DisplayBox {
    const offset_x = clampOffset(request.offset_x, request.cell_width);
    const offset_y = clampOffset(request.offset_y, request.cell_height);
    const filled_width = std.math.mul(u32, request.cell_width, request.columns) catch std.math.maxInt(u32);
    const filled_height = std.math.mul(u32, request.cell_height, request.rows) catch std.math.maxInt(u32);

    var width = request.source_width;
    var height = request.source_height;
    if (request.columns != 0 and request.rows != 0) {
        width = filled_width -| offset_x;
        height = filled_height -| offset_y;
    } else if (request.columns != 0) {
        width = filled_width -| offset_x;
        height = scale(width, request.source_height, request.source_width);
    } else if (request.rows != 0) {
        height = filled_height -| offset_y;
        width = scale(height, request.source_width, request.source_height);
    }

    return .{
        .offset_x = offset_x,
        .offset_y = offset_y,
        .width = width,
        .height = height,
    };
}

/// The cells the placement covers: the requested ones when both are
/// given, else its drawn box plus offset rounded up to whole cells, as
/// Ghostty's `gridSize` does.
///
/// ```zig
/// const covered = display.cells(.{ .source_width = 640, .source_height = 480, .cell_width = 16, .cell_height = 32 });
/// ```
pub fn cells(request: DisplayRequest) DisplayCells {
    if (request.columns != 0 and request.rows != 0) {
        return .{
            .columns = request.columns,
            .rows = request.rows,
        };
    }

    if (request.cell_width == 0 or request.cell_height == 0) {
        return .{
            .columns = 0,
            .rows = 0,
        };
    }

    const drawn = box(request);
    return .{
        // SAFETY: The zero-cell-size guard above excludes division by zero; the numerator uses saturating addition.
        .columns = std.math.divCeil(u32, drawn.width +| drawn.offset_x, request.cell_width) catch unreachable,
        // SAFETY: The zero-cell-size guard above excludes division by zero; the numerator uses saturating addition.
        .rows = std.math.divCeil(u32, drawn.height +| drawn.offset_y, request.cell_height) catch unreachable,
    };
}

/// Example: `if (display.layer(placement.z_index) == .above_text) { ... }`.
pub fn layer(z_index: i32) Layer {
    if (z_index < below_background_limit) {
        return .below_background;
    }

    if (z_index < 0) {
        return .below_text;
    }

    return .above_text;
}

fn clampOffset(offset: u32, cell: u32) u32 {
    if (cell == 0) {
        return 0;
    }

    return @min(offset, cell - 1);
}

fn scale(value: u32, numerator: u32, denominator: u32) u32 {
    if (denominator == 0) {
        return 0;
    }

    const rounded = (@as(u64, value) * numerator + denominator / 2) / denominator;
    return std.math.cast(u32, rounded) orelse std.math.maxInt(u32);
}
