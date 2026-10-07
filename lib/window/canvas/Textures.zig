//! Borrowed texture pages used by one quad batch; valid until canvas completion.
const gfx = @import("gfx");

atlas: ?[*]const u8 = null,
atlas_side: u32 = 0,
atlas_version: u32 = 0,
atlas_dirty_base: u32 = 0,
atlas_dirty_top: u32 = 0,
atlas_dirty_bottom: u32 = 0,
sprites: ?[*]const u8 = null,
sprites_side: u32 = 0,
sprites_version: u32 = 0,
diagrams: [gfx.Quad.diagram_slot_count]gfx.DiagramTexture.DiagramTexture = @splat(.{}),
