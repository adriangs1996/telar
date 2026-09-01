//! Notification and sidebar flows owned by the client application.

pub const notifications = @import("notifications.zig");
pub const sidebar_animation = @import("sidebar_animation.zig");
pub const sidebar_visibility_delivery = @import("sidebar_visibility_delivery.zig");
pub const toggle_sidebar = @import("toggle_sidebar.zig");

test {
    _ = notifications;
    _ = sidebar_animation;
    _ = sidebar_visibility_delivery;
    _ = toggle_sidebar;
}
