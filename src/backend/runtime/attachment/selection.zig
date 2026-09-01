//! Bounded extraction of terminal selections in absolute scrollback coordinates.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");

const schema = core.schema;
const Pane = pane_mod.Pane;

pub const scratch_bytes = 2 * schema.max_clipboard_bytes + 1;

pub const Range = struct {
    start_x: u16,
    start_y: u32,
    end_x: u16,
    end_y: u32,
    linewise: bool,
};

pub const Result = union(enum) {
    copied: []const u8,
    unavailable,
    too_large,
};

const Point = struct {
    x: u16,
    y: u32,
};

const Endpoints = struct {
    start: Point,
    end: Point,
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

    if (selected.len > schema.max_clipboard_bytes) {
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
