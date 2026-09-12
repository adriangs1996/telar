//! An owned cell and its compiled geometry. Never borrows a model or atlas slot.
const std = @import("std");
const Paint = @import("CellPaint.zig");
const Quad = @import("Quad.zig").Quad;
const Mesh = @This();

pub const capacity = 24;
valid: bool = false,
paint: Paint = undefined,
quads: [capacity]Quad = undefined,
len: u8 = 0,

pub fn matches(mesh: *const Mesh, paint: Paint) bool {
    return mesh.valid and mesh.paint.rect.x == paint.rect.x and mesh.paint.rect.y == paint.rect.y and
        mesh.paint.rect.width == paint.rect.width and mesh.paint.rect.height == paint.rect.height and
        mesh.paint.cell.eqlPublic(&paint.cell);
}

/// Commits only a complete cell preparation. Example: `mesh.replace(paint, quads);`
pub fn replace(mesh: *Mesh, paint: Paint, quads: []const Quad) void {
    std.debug.assert(quads.len <= capacity);
    @memcpy(mesh.quads[0..quads.len], quads);
    mesh.len = @intCast(quads.len);
    mesh.paint = paint;
    mesh.valid = true;
}

pub fn items(mesh: *const Mesh) []const Quad {
    return mesh.quads[0..mesh.len];
}
