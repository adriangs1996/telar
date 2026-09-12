//! What Zig hands the backend for one paint: the quads and the alpha page
//! they sample. Mirrors `telar_gui_frame` in `native/telar_gui.h`.
const Quad = @import("../render/Quad.zig").Quad;

pub const Frame = extern struct {
    quads: ?[*]const Quad,
    quad_count: u32,
    atlas: ?[*]const u8,
    atlas_side: u32,
    atlas_version: u32,
    background: [4]f32,
};
