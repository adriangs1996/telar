//! Untrusted image decoding for icons and attachments: PNG through Wuffs
//! with dimension limits checked before any pixel buffer, ICO frames, a box
//! filter that resamples straight RGBA, and bilinear sampling of a square
//! of RGBA artwork.

pub const Bitmap = @import("Bitmap.zig");
pub const ImageView = @import("ImageView.zig");
pub const bilinear = @import("bilinear.zig");
pub const box_filter = @import("box_filter.zig");
pub const ico = @import("ico.zig");
pub const png = @import("png.zig");
pub const premultiply = @import("premultiply.zig");
pub const testing = @import("testing.zig");

test {
    _ = @import("Bitmap.zig");
    _ = @import("DecodedImage.zig");
    _ = @import("IcoFrame.zig");
    _ = @import("ImageView.zig");
    _ = @import("PngHeader.zig");
    _ = @import("PngTestSpec.zig");
    _ = @import("bilinear.zig");
    _ = @import("box_filter.zig");
    _ = @import("ico.zig");
    _ = @import("png.zig");
    _ = @import("premultiply.zig");
}
