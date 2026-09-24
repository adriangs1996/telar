//! Synchronous view of one retained row segment. All slices have the same
//! length and expire on grid resize or destruction.
const Metadata = @import("CellMetadata.zig");
const Mesh = @import("CellMesh.zig");
const gfx = @import("gfx");
const Quad = gfx.Quad.Quad;
const Row = @This();

metadata: []Metadata,
primary: [][Mesh.primary_capacity]Quad,
overflow: [][Mesh.overflow_capacity]Quad,

/// Borrows one cell of the row. Example: `const mesh = row.at(col);`
pub fn at(self: Row, index: usize) Mesh {
    return .{
        .metadata = &self.metadata[index],
        .primary = &self.primary[index],
        .overflow = &self.overflow[index],
    };
}
