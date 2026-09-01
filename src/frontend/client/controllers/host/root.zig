//! Client adapters for host observations and resources.

pub const clipboard_images = @import("clipboard_images.zig");
pub const host_capabilities = @import("host_capabilities.zig");
pub const host_resizes = @import("host_resizes.zig");
pub const host_resources = @import("host_resources.zig");

test {
    _ = clipboard_images;
    _ = host_capabilities;
    _ = host_resizes;
    _ = host_resources;
}
