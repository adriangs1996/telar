//! Resolves a placement's drawn size and layer the way kitty and Ghostty
//! draw classic placements.

const std = @import("std");
const DisplayBox = @import("DisplayBox.zig");
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

test "a placement without cells keeps its natural size" {
    const resolved = box(.{
        .source_width = 640,
        .source_height = 480,
        .cell_width = 16,
        .cell_height = 32,
    });
    try std.testing.expectEqual(DisplayBox{ .offset_x = 0, .offset_y = 0, .width = 640, .height = 480 }, resolved);
}

test "columns and rows stretch the image less the offset" {
    const resolved = box(.{
        .source_width = 640,
        .source_height = 480,
        .columns = 10,
        .rows = 2,
        .offset_x = 3,
        .offset_y = 5,
        .cell_width = 16,
        .cell_height = 32,
    });
    try std.testing.expectEqual(DisplayBox{ .offset_x = 3, .offset_y = 5, .width = 157, .height = 59 }, resolved);
}

test "one side follows the source aspect ratio" {
    const by_columns = box(.{
        .source_width = 640,
        .source_height = 480,
        .columns = 20,
        .cell_width = 16,
        .cell_height = 32,
    });
    try std.testing.expectEqual(@as(u32, 320), by_columns.width);
    try std.testing.expectEqual(@as(u32, 240), by_columns.height);

    const by_rows = box(.{
        .source_width = 3,
        .source_height = 2,
        .rows = 1,
        .cell_width = 16,
        .cell_height = 33,
    });
    try std.testing.expectEqual(@as(u32, 33), by_rows.height);
    try std.testing.expectEqual(@as(u32, 50), by_rows.width);
}

test "offsets stay inside the cell and never underflow the size" {
    const resolved = box(.{
        .source_width = 8,
        .source_height = 8,
        .columns = 1,
        .rows = 1,
        .offset_x = 99,
        .offset_y = 99,
        .cell_width = 10,
        .cell_height = 20,
    });
    try std.testing.expectEqual(DisplayBox{ .offset_x = 9, .offset_y = 19, .width = 1, .height = 1 }, resolved);
}

test "huge cell requests saturate instead of overflowing" {
    const resolved = box(.{
        .source_width = 1,
        .source_height = 1,
        .columns = std.math.maxInt(u32),
        .rows = std.math.maxInt(u32),
        .cell_width = 16,
        .cell_height = 32,
    });
    try std.testing.expectEqual(std.math.maxInt(u32), resolved.width);
    try std.testing.expectEqual(std.math.maxInt(u32), resolved.height);
}

test "z-index picks the layer with strict boundaries" {
    try std.testing.expectEqual(Layer.below_background, layer(below_background_limit - 1));
    try std.testing.expectEqual(Layer.below_text, layer(below_background_limit));
    try std.testing.expectEqual(Layer.below_text, layer(-1));
    try std.testing.expectEqual(Layer.above_text, layer(0));
    try std.testing.expectEqual(Layer.below_background, layer(std.math.minInt(i32)));
}
