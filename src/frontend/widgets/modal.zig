//! Shared geometry for application-level modal overlays.

const ui = @import("../ui/root.zig");

const size_numerator: u32 = 4;
const size_denominator: u32 = 5;

/// Returns a rectangle that occupies 80% of each application dimension and
/// centers the result inside the application area.
///
/// ```zig
/// const area = modal.area(context.buffer.area());
/// ```
pub fn area(application: ui.Rect) ui.Rect {
    const width: u16 = @intCast(@as(u32, application.w) * size_numerator / size_denominator);
    const height: u16 = @intCast(@as(u32, application.h) * size_numerator / size_denominator);

    return .{
        .x = application.x +| (application.w - width) / 2,
        .y = application.y +| (application.h - height) / 2,
        .w = width,
        .h = height,
    };
}

test "modal occupies eighty percent of the application and stays centered" {
    const std = @import("std");

    try std.testing.expectEqual(ui.Rect{ .x = 22, .y = 14, .w = 96, .h = 32 }, area(.{
        .x = 10,
        .y = 10,
        .w = 120,
        .h = 40,
    }));
}

test "modal centers odd remainders without exceeding its application area" {
    const std = @import("std");

    try std.testing.expectEqual(ui.Rect{ .x = 10, .y = 2, .w = 80, .h = 19 }, area(.{
        .w = 101,
        .h = 24,
    }));
}
