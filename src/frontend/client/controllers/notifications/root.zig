//! Client adapters for notifications and sidebar state.

pub const notifications = @import("notifications.zig");
pub const sidebar_animations = @import("sidebar_animations.zig");
pub const sidebar_projection = @import("sidebar_projection.zig");
pub const sidebar_toggles = @import("sidebar_toggles.zig");

test {
    _ = notifications;
    _ = sidebar_animations;
    _ = sidebar_projection;
    _ = sidebar_toggles;
}
