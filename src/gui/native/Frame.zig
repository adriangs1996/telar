//! What Zig hands the backend for one paint: the quads, the alpha page and
//! the RGBA sprite page they sample. Mirrors `telar_gui_frame` in
//! `native/telar_gui.h`.
const Quad = @import("../render/Quad.zig").Quad;

pub const Frame = extern struct {
    // Zero defers submission until another consumer wake or viewport change.
    token: u64 = 0,
    quads: ?[*]const Quad,
    quad_count: u32,
    atlas: ?[*]const u8,
    atlas_side: u32,
    atlas_version: u32,
    sprites: ?[*]const u8 = null,
    sprites_side: u32 = 0,
    sprites_version: u32 = 0,
    background: [4]f32,
    background_blur: u32 = 0,
    titlebar: u32 = 1,
};
