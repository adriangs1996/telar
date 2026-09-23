//! Adapter-owned cell geometry, indexed by workbench position. Comparing owned
//! visual inputs also detects changes after skipped/coalesced model revisions.
//! This is preparation reuse, not delivery state: retry still submits the scene.
const std = @import("std");
const Mesh = @import("CellMesh.zig");
const Metadata = @import("CellMetadata.zig");
const Paint = @import("CellPaint.zig");
const Quad = @import("Quad.zig").Quad;
const Row = @import("CellRow.zig");
const Grid = @This();

pub const max_cells = 65536;

allocator: std.mem.Allocator,
entries: std.ArrayList(Metadata) = .empty,
primary: std.ArrayList([Mesh.primary_capacity]Quad) = .empty,
overflow: std.ArrayList([Mesh.overflow_capacity]Quad) = .empty,
cols: u16 = 0,
rows: u16 = 0,

pub fn init(allocator: std.mem.Allocator) Grid {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Grid) void {
    self.entries.deinit(self.allocator);
    self.primary.deinit(self.allocator);
    self.overflow.deinit(self.allocator);
}

/// Geometry changes invalidate positions; steady frames allocate nothing.
/// Example: `try grid.resize(.{ cols, rows });`
pub fn resize(self: *Grid, size: [2]u16) !void {
    if (self.cols == size[0] and self.rows == size[1]) {
        return;
    }

    const count = @as(usize, size[0]) * size[1];
    if (count > max_cells) {
        return error.NativeCellBudgetExceeded;
    }

    try self.entries.ensureTotalCapacityPrecise(self.allocator, count);
    try self.primary.ensureTotalCapacityPrecise(self.allocator, count);
    try self.overflow.ensureTotalCapacityPrecise(self.allocator, count);
    self.entries.items.len = count;
    self.primary.items.len = count;
    self.overflow.items.len = count;
    self.cols = size[0];
    self.rows = size[1];
    self.invalidate();
}

/// Use when font resources or global colors change. Example: `grid.invalidate();`
pub fn invalidate(self: *Grid) void {
    for (self.entries.items) |*entry| {
        entry.valid = false;
    }
}

/// Borrows every array until resize or deinit. Example: `grid.at(.{ x, y }).background();`
pub fn at(self: *Grid, position: [2]u16) Mesh {
    std.debug.assert(position[0] < self.cols and position[1] < self.rows);
    const index = @as(usize, position[1]) * self.cols + position[0];
    return .{
        .metadata = &self.entries.items[index],
        .primary = &self.primary.items[index],
        .overflow = &self.overflow.items[index],
    };
}

/// Borrows `len` consecutive cells starting at `position` until resize or
/// deinit. Example: `const row = grid.row(.{ x, y }, cols);`
pub fn row(self: *Grid, position: [2]u16, len: u16) Row {
    std.debug.assert(position[1] < self.rows and @as(usize, position[0]) + len <= self.cols);
    const start = @as(usize, position[1]) * self.cols + position[0];
    return .{
        .metadata = self.entries.items[start..][0..len],
        .primary = self.primary.items[start..][0..len],
        .overflow = self.overflow.items[start..][0..len],
    };
}

test "grid budget failures preserve the previous cache" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    try grid.resize(.{ 80, 24 });
    try std.testing.expectError(error.NativeCellBudgetExceeded, grid.resize(.{ 65535, 2 }));
    try std.testing.expectEqual(@as(u16, 80), grid.cols);
    try std.testing.expectEqual(@as(u16, 24), grid.rows);
}

test "split storage keeps the previous grid usable after either allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, resizeWithFailures, .{});
}

fn resizeWithFailures(allocator: std.mem.Allocator) !void {
    var grid = Grid.init(allocator);
    defer grid.deinit();
    try grid.resize(.{ 2, 2 });
    const paint: Paint = .{
        .cell = .{},
        .rect = .{
            .x = 0,
            .y = 0,
            .width = 10,
            .height = 20,
        },
    };
    const quads = [_]Quad{std.mem.zeroes(Quad)};
    grid.at(.{ 1, 1 }).replace(paint, &quads);

    grid.resize(.{ 16, 16 }) catch |err| {
        try std.testing.expectEqual(@as(u16, 2), grid.cols);
        try std.testing.expectEqual(@as(u16, 2), grid.rows);
        try std.testing.expectEqual(@as(usize, 4), grid.entries.items.len);
        try std.testing.expectEqual(@as(usize, 4), grid.primary.items.len);
        try std.testing.expectEqual(@as(usize, 4), grid.overflow.items.len);
        try std.testing.expect(grid.at(.{ 1, 1 }).matches(paint));
        var storage: [Mesh.capacity]Quad = undefined;
        try std.testing.expectEqualSlices(Quad, &quads, grid.at(.{ 1, 1 }).collect(&storage));
        return err;
    };

    try std.testing.expectEqual(@as(usize, 256), grid.entries.items.len);
    try std.testing.expectEqual(grid.entries.items.len, grid.primary.items.len);
    try std.testing.expectEqual(grid.entries.items.len, grid.overflow.items.len);
    try std.testing.expect(!grid.at(.{ 1, 1 }).matches(paint));
    for (grid.entries.items) |entry| {
        try std.testing.expect(!entry.valid);
    }
}
