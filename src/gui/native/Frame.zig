//! What Zig hands the backend for one paint: the quads and the alpha page
//! they sample. Mirrors `telar_gui_frame` in `native/telar_gui.h`.
const Quad = @import("../render/Quad.zig").Quad;

pub const Frame = extern struct {
    // Zero defers submission until another consumer wake or viewport change.
    token: u64 = 0,
    quads: ?[*]const Quad,
    quad_count: u32,
    atlas: ?[*]const u8,
    atlas_side: u32,
    atlas_version: u32,
    background: [4]f32,
    background_blur: u32 = 0,
    titlebar: u32 = 1,
};
