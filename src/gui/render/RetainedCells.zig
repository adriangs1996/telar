//! Adapter-owned cell geometry, indexed by workbench position. Comparing owned
//! visual inputs also detects changes after skipped/coalesced model revisions.
//! This is preparation reuse, not delivery state: retry still submits the scene.
const std = @import("std");
const Mesh = @import("CellMesh.zig");
const Metadata = @import("CellMetadata.zig");
const gfx = @import("gfx");
const Quad = gfx.Quad.Quad;
const Row = @import("CellRow.zig");
const core = @import("telar-core");
const Grid = @This();

/// Every grid the protocol carries: the window measures no more cells than
/// `core.max_cell_count`, so this bound never binds first. Storage follows
/// the grid's actual cells, not this bound.
pub const max_cells = core.max_cell_count;

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
