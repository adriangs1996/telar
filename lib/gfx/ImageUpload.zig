//! One Kitty graphics image the backend uploads off the window thread.
//! Mirrors `telar_gui_image_upload` in `native/telar_gui.h`; the pixels stay
//! borrowed until `image_ready` reports the handle.

pub const ImageUpload = extern struct {
    pixels: [*]const u8,
    handle: u32,
    width: u32,
    height: u32,
    /// 3 for RGB, 4 for RGBA with straight alpha.
    bytes_per_pixel: u32,
};

/// Mirrors `TELAR_GUI_IMAGE_CAPACITY`: handles run from 1 to this value.
pub const capacity = 512;
/// Mirrors `TELAR_GUI_IMAGE_MAX_SIDE`.
pub const max_side = 16384;
/// Mirrors `TELAR_GUI_IMAGE_UPLOADS`: uploads in flight at once.
pub const uploads_in_flight = 4;
