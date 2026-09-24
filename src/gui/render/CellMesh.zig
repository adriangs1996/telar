//! Synchronous view into adapter-owned metadata and geometry. A grid resize
//! invalidates the view; no model or atlas storage is borrowed.
//!
//! Geometry is split by access frequency. Every warm draw reads the
//! background and the first ink quad, so they live in a dense `primary`
//! array. Underlines, strikethroughs and multi-glyph clusters spill into a
//! cold `overflow` array that warm draws touch only for the cells using it.
const cellgrid = @import("cellgrid");
const std = @import("std");
const Paint = @import("CellPaint.zig");
const Metadata = @import("CellMetadata.zig");
const gfx = @import("gfx");
const Quad = gfx.Quad.Quad;
const Color = gfx.Color;
const Rect = gfx.Rect;
const Mesh = @This();

pub const capacity = 24;
pub const primary_capacity = 2;
pub const overflow_capacity = capacity - primary_capacity;
metadata: *Metadata,
primary: *[primary_capacity]Quad,
overflow: *[overflow_capacity]Quad,

/// Compares the complete visual key. Example: `if (mesh.matches(paint)) reuse();`
pub fn matches(self: Mesh, paint: Paint) bool {
    return self.matchesCell(&paint.cell, paint.rect);
}

/// Compares against a cell still in its source buffer, so the warm draw
/// loads it straight from memory instead of copying it into a key first.
/// Example: `if (mesh.matchesCell(&row[x], rect)) reuse();`
pub fn matchesCell(self: Mesh, cell: *const cellgrid.Cell, rect: Rect) bool {
    const cached = self.metadata;
    return cached.valid and cached.paint.rect.x == rect.x and cached.paint.rect.y == rect.y and
        cached.paint.rect.width == rect.width and cached.paint.rect.height == rect.height and
        cached.paint.cell.eqlPublic(cell);
}

/// Commits only a complete cell preparation. Example: `mesh.replace(paint, quads);`
pub fn replace(self: Mesh, paint: Paint, quads: []const Quad) void {
    std.debug.assert(quads.len >= 1 and quads.len <= capacity);
    const split = @min(quads.len, primary_capacity);
    @memcpy(self.primary[0..split], quads[0..split]);
    @memcpy(self.overflow[0 .. quads.len - split], quads[split..]);
    self.metadata.len = @intCast(quads.len);
    self.metadata.paint = paint;
    self.metadata.valid = true;
}

/// Records whether the background quad must be drawn against the theme
/// background, so warm draws never read geometry for default cells.
/// Example: `mesh.classifyBackground(renderer.background);`
pub fn classifyBackground(self: Mesh, theme: Color) void {
    const fill = self.primary[0];
    self.metadata.background = fill.r != theme.r or fill.g != theme.g or fill.b != theme.b;
}

/// The retained background quad. Example: `try quads.push(mesh.background());`
pub fn background(self: Mesh) Quad {
    return self.primary[0];
}

/// Borrows the ink stored densely beside the background.
/// Example: `for (mesh.primaryInk()) |quad| draw(quad);`
pub fn primaryInk(self: Mesh) []const Quad {
    return self.primary[1..@min(self.metadata.len, primary_capacity)];
}

/// Borrows the ink that did not fit in primary storage.
/// Example: `for (mesh.overflowInk()) |quad| draw(quad);`
pub fn overflowInk(self: Mesh) []const Quad {
    return self.overflow[0..self.metadata.len -| primary_capacity];
}

/// Gathers the complete geometry in draw order into caller storage.
/// Example: `var storage: [CellMesh.capacity]Quad = undefined; const all = mesh.collect(&storage);`
pub fn collect(self: Mesh, storage: *[capacity]Quad) []const Quad {
    const len = self.metadata.len;
    const split = @min(len, primary_capacity);
    @memcpy(storage[0..split], self.primary[0..split]);
    @memcpy(storage[split..len], self.overflow[0 .. len - split]);
    return storage[0..len];
}
