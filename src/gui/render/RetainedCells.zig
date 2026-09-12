//! Adapter-owned cell geometry, indexed by workbench position. Comparing owned
//! visual inputs also detects changes after skipped/coalesced model revisions.
//! This is preparation reuse, not delivery state: retry still submits the scene.
const std = @import("std");
const Mesh = @import("CellMesh.zig");
const Grid = @This();

pub const max_cells = 65536;

allocator: std.mem.Allocator,
entries: std.ArrayList(Mesh) = .empty,
cols: u16 = 0,
rows: u16 = 0,

pub fn init(allocator: std.mem.Allocator) Grid {
    return .{ .allocator = allocator };
}

pub fn deinit(grid: *Grid) void {
    grid.entries.deinit(grid.allocator);
}

/// Geometry changes invalidate positions; steady frames allocate nothing.
/// Example: `try grid.resize(.{ cols, rows });`
pub fn resize(grid: *Grid, size: [2]u16) !void {
    if (grid.cols == size[0] and grid.rows == size[1]) {
        return;
    }

    const count = @as(usize, size[0]) * size[1];
    if (count > max_cells) {
        return error.NativeCellBudgetExceeded;
    }

    try grid.entries.ensureTotalCapacityPrecise(grid.allocator, count);
    try grid.entries.resize(grid.allocator, count);
    grid.cols = size[0];
    grid.rows = size[1];
    grid.invalidate();
}

/// Use when font resources or global colors change. Example: `grid.invalidate();`
pub fn invalidate(grid: *Grid) void {
    for (grid.entries.items) |*entry| {
        entry.valid = false;
    }
}

pub fn at(grid: *Grid, position: [2]u16) *Mesh {
    std.debug.assert(position[0] < grid.cols and position[1] < grid.rows);
    return &grid.entries.items[@as(usize, position[1]) * grid.cols + position[0]];
}

test "grid budget failures preserve the previous cache" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    try grid.resize(.{ 80, 24 });
    try std.testing.expectError(error.NativeCellBudgetExceeded, grid.resize(.{ 65535, 2 }));
    try std.testing.expectEqual(@as(u16, 80), grid.cols);
    try std.testing.expectEqual(@as(u16, 24), grid.rows);
}
