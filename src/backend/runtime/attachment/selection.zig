//! Bounded extraction of terminal selections in absolute scrollback coordinates.

const max_clipboard_bytes_module = @import("telar-core").max_clipboard_bytes;
const Pane = @import("../../pane/Pane.zig");
const Range = @import("Range.zig");
const std = @import("std");
const vt = @import("ghostty-vt");
const Endpoints = @import("Endpoints.zig");
const Point = @import("Point.zig");

pub const scratch_bytes = 2 * max_clipboard_bytes_module + 1;

pub const Result = union(enum) {
    copied: []const u8,
    unavailable,
    too_large,
};

/// Extracts one inclusive range into caller-owned fixed storage. Returned bytes
/// borrow `scratch` and remain valid until that storage is reused. Oversized
/// selections never allocate outside the supplied buffer.
///
/// ```zig
/// var scratch: [scratch_bytes]u8 = undefined;
/// const result = extract(pane, range, &scratch);
/// ```
pub fn extract(pane: *Pane, range: Range, scratch: []u8) Result {
    const endpoints = resolveEndpoints(range, pane.screen.w) orelse return .unavailable;
    const screen = pane.terminal.screens.active;
    const bottom = screen.pages.getBottomRight(.screen) orelse return .unavailable;
    const start = screen.pages.pin(.{ .screen = .{
        .x = endpoints.start.x,
        .y = endpoints.start.y,
    } }) orelse bottom;
    const finish = screen.pages.pin(.{ .screen = .{
        .x = endpoints.end.x,
        .y = endpoints.end.y,
    } }) orelse bottom;

    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const selected = screen.selectionString(fixed.allocator(), .{
        .sel = vt.Selection.init(start, finish, false),
    }) catch return .too_large;

    if (selected.len > max_clipboard_bytes_module) {
        return .too_large;
    }

    return .{ .copied = selected };
}

fn resolveEndpoints(range: Range, cols: u16) ?Endpoints {
    if (cols == 0) {
        return null;
    }

    if (range.linewise) {
        return .{
            .start = .{ .x = 0, .y = @min(range.start_y, range.end_y) },
            .end = .{ .x = cols - 1, .y = @max(range.start_y, range.end_y) },
        };
    }

    return .{
        .start = .{ .x = @min(range.start_x, cols - 1), .y = range.start_y },
        .end = .{ .x = @min(range.end_x, cols - 1), .y = range.end_y },
    };
}

test "linewise endpoints cover full rows in reading order" {
    const endpoints = resolveEndpoints(.{
        .start_x = 7,
        .start_y = 9,
        .end_x = 3,
        .end_y = 4,
        .linewise = true,
    }, 12).?;

    try std.testing.expectEqualDeep(Point{ .x = 0, .y = 4 }, endpoints.start);
    try std.testing.expectEqualDeep(Point{ .x = 11, .y = 9 }, endpoints.end);
}

test "linear endpoints clamp columns without changing drag direction" {
    const endpoints = resolveEndpoints(.{
        .start_x = 40,
        .start_y = 7,
        .end_x = 3,
        .end_y = 2,
        .linewise = false,
    }, 10).?;

    try std.testing.expectEqualDeep(Point{ .x = 9, .y = 7 }, endpoints.start);
    try std.testing.expectEqualDeep(Point{ .x = 3, .y = 2 }, endpoints.end);
}

test "a zero-width pane has no selectable endpoints" {
    try std.testing.expect(resolveEndpoints(.{
        .start_x = 0,
        .start_y = 0,
        .end_x = 0,
        .end_y = 0,
        .linewise = false,
    }, 0) == null);
}
