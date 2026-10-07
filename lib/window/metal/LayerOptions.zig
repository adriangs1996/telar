const Size = @import("Size.zig").Size;
const PixelFormat = @import("PixelFormat.zig").PixelFormat;

size: Size,
format: PixelFormat,
framebuffer_only: bool,
display_sync: bool,
