//! Host observation and resource flows owned by the client application.

pub const host_capabilities = @import("host_capabilities.zig");
pub const host_resize = @import("host_resize.zig");
pub const host_resource_delivery = @import("host_resource_delivery.zig");

test {
    _ = host_capabilities;
    _ = host_resize;
    _ = host_resource_delivery;
}
