//! Untrusted image decoding for icons and attachments: PNG through Wuffs
//! with dimension limits checked before any pixel buffer, ICO frames, and a
//! box filter that resamples straight RGBA.

pub const ImageView = @import("ImageView.zig");
pub const box_filter = @import("box_filter.zig");
pub const ico = @import("ico.zig");
pub const png = @import("png.zig");
pub const testing = @import("testing.zig");

test {
    _ = @import("DecodedImage.zig");
    _ = @import("IcoFrame.zig");
    _ = @import("ImageView.zig");
    _ = @import("PngHeader.zig");
    _ = @import("PngTestSpec.zig");
    _ = @import("box_filter.zig");
    _ = @import("ico.zig");
    _ = @import("png.zig");
}
