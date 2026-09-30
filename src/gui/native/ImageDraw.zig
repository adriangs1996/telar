//! One quad that samples a Kitty graphics image. Mirrors
//! `telar_gui_image_draw` in `native/telar_gui.h`.

pub const ImageDraw = extern struct {
    quad: u32,
    handle: u32,
};

/// Mirrors `TELAR_GUI_IMAGE_DRAWS`: image quads one frame may draw.
pub const capacity = 512;
