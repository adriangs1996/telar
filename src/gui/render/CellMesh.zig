//! Synchronous view into adapter-owned metadata and geometry. A grid resize
//! invalidates the view; no model or atlas storage is borrowed.
const std = @import("std");
const Paint = @import("CellPaint.zig");
const Metadata = @import("CellMetadata.zig");
const Quad = @import("Quad.zig").Quad;
const Mesh = @This();

pub const capacity = 24;
metadata: *Metadata,
quads: *[capacity]Quad,

/// Compares the complete visual key. Example: `if (mesh.matches(paint)) reuse();`
pub fn matches(self: Mesh, paint: Paint) bool {
    const cached = self.metadata;
    return cached.valid and cached.paint.rect.x == paint.rect.x and cached.paint.rect.y == paint.rect.y and
        cached.paint.rect.width == paint.rect.width and cached.paint.rect.height == paint.rect.height and
        cached.paint.cell.eqlPublic(&paint.cell);
}

/// Commits only a complete cell preparation. Example: `mesh.replace(paint, quads);`
pub fn replace(self: Mesh, paint: Paint, quads: []const Quad) void {
    std.debug.assert(quads.len <= capacity);
    @memcpy(self.quads[0..quads.len], quads);
    self.metadata.len = @intCast(quads.len);
    self.metadata.paint = paint;
    self.metadata.valid = true;
}

/// Borrows the initialized geometry prefix. Example: `draw(mesh.items());`
pub fn items(self: Mesh) []const Quad {
    return self.quads[0..self.metadata.len];
}
