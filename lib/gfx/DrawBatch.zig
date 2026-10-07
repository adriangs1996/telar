//! Borrowed prepared drawing data. Keep its storage unchanged until completion.
const quad = @import("Quad.zig");
const image_draw = @import("ImageDraw.zig");
const image_upload = @import("ImageUpload.zig");
const Quad = quad.Quad;
const diagram = @import("DiagramTexture.zig");
const ImageDraw = image_draw.ImageDraw;
const ImageUpload = image_upload.ImageUpload;

pub const DrawBatch = extern struct {
    // Opaque identity returned with the surface completion.
    token: u64 = 0,
    quads: ?[*]const Quad = null,
    quad_count: u32 = 0,
    atlas: ?[*]const u8 = null,
    atlas_side: u32 = 0,
    atlas_version: u32 = 0,
    sprites: ?[*]const u8 = null,
    sprites_side: u32 = 0,
    sprites_version: u32 = 0,
    diagrams: [quad.diagram_slot_count]diagram.DiagramTexture = @splat(.{}),
    background: [4]f32,
    background_blur: u32 = 0,
    titlebar: u32 = 1,
    /// Device pixels of the navigation row native window controls center on.
    navigation: u32 = 0,
    /// Accepted only when draw returns true; pixels stay borrowed until image completion.
    image_uploads: ?[*]const ImageUpload = null,
    image_upload_count: u32 = 0,
    image_releases: ?[*]const u32 = null,
    image_release_count: u32 = 0,
    image_draws: ?[*]const ImageDraw = null,
    image_draw_count: u32 = 0,
    /// The atlas version a backend must hold to upload only rows
    /// `atlas_dirty_top..atlas_dirty_bottom`; any other uploads the page.
    atlas_dirty_base: u32 = 0,
    atlas_dirty_top: u32 = 0,
    atlas_dirty_bottom: u32 = 0,
};
