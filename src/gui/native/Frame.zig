//! What Zig hands the backend for one paint: the quads, the alpha page and
//! the RGBA sprite page and bounded diagram textures they sample. Mirrors `telar_gui_frame` in
//! `native/telar_gui.h`.
const diagram = @import("DiagramTexture.zig");
const ImageDraw = @import("ImageDraw.zig").ImageDraw;
const ImageUpload = @import("ImageUpload.zig").ImageUpload;
const gfx = @import("gfx");
const Quad = gfx.Quad.Quad;

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
    diagrams: [gfx.Quad.diagram_slot_count]diagram.DiagramTexture = @splat(.{}),
    background: [4]f32,
    background_blur: u32 = 0,
    titlebar: u32 = 1,
    /// Device pixels of the navigation row native window controls center on.
    navigation: u32 = 0,
    /// Taken when render returns, submitted or not; see `telar_gui_frame`.
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

test "native diagram descriptors preserve the C frame layout" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(diagram.DiagramTexture));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(diagram.DiagramTexture, "version"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(Frame, "diagrams"));
    try std.testing.expectEqual(@as(usize, 336), @sizeOf(Frame));
    try std.testing.expectEqual(@as(usize, 324), @offsetOf(Frame, "atlas_dirty_base"));
    try std.testing.expectEqual(@as(usize, 272), @offsetOf(Frame, "navigation"));
    try std.testing.expectEqual(@as(usize, 280), @offsetOf(Frame, "image_uploads"));
    try std.testing.expectEqual(@as(usize, 320), @offsetOf(Frame, "image_draw_count"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ImageUpload));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ImageDraw));
}

test "the native headers and their Zig mirrors agree on every bound" {
    const std = @import("std");
    const event = @import("../input/event.zig");
    const AccessibilityTree = @import("AccessibilityTree.zig");
    const ImageDrawBound = @import("ImageDraw.zig");
    const ImageUploadBound = @import("ImageUpload.zig");
    const GlyphAtlas = @import("../text/GlyphAtlas.zig");
    const header = @cImport({
        @cInclude("telar_gui.h");
        @cInclude("glyph_rasterizer.h");
    });
    try std.testing.expectEqual(@as(usize, header.TELAR_GUI_CLIPBOARD_CAPACITY), event.max_text_bytes);
    try std.testing.expectEqual(@as(usize, header.TELAR_GUI_TEXT_CAPACITY), event.max_composition_bytes);
    try std.testing.expectEqual(@as(usize, header.TELAR_GUI_IMAGE_DRAWS), ImageDrawBound.capacity);
    try std.testing.expectEqual(@as(usize, header.TELAR_GUI_IMAGE_CAPACITY), ImageUploadBound.capacity);
    try std.testing.expectEqual(@as(usize, header.TELAR_GUI_IMAGE_MAX_SIDE), ImageUploadBound.max_side);
    try std.testing.expectEqual(@as(usize, header.TELAR_GUI_IMAGE_UPLOADS), ImageUploadBound.uploads_in_flight);
    try std.testing.expectEqual(@as(usize, header.TELAR_GUI_DIAGRAM_SLOTS), gfx.Quad.diagram_slot_count);
    try std.testing.expectEqual(@as(usize, header.TELAR_GUI_DIAGRAM_MAX_SIDE), diagram.max_side);
    try std.testing.expectEqual(@as(usize, header.TELAR_GUI_DIAGRAM_MAX_PIXELS), diagram.max_pixels);
    try std.testing.expectEqual(@as(usize, header.TELAR_GUI_DIAGRAM_FRAME_PIXELS), diagram.max_frame_pixels);
    try std.testing.expectEqual(@as(usize, header.TELAR_GUI_ACCESSIBILITY_CAPACITY), AccessibilityTree.capacity);
    try std.testing.expectEqual(@as(u32, header.TELAR_GLYPH_ATLAS_MAX_SIDE), GlyphAtlas.max_side);
    try std.testing.expectEqual(@sizeOf(header.telar_gui_frame), @sizeOf(Frame));
}
