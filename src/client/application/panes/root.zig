//! Pane lifecycle and synchronization flows owned by the client application.

pub const active_pane_resource_delivery = @import("active_pane_resource_delivery.zig");
pub const attach_pane = @import("attach_pane.zig");
pub const close_pane = @import("close_pane.zig");
pub const focus_pane = @import("focus_pane.zig");
pub const pane_closure_delivery = @import("pane_closure_delivery.zig");
pub const pane_focus_reporting = @import("pane_focus_reporting.zig");
pub const pane_frame = @import("pane_frame.zig");
pub const pane_attachment_requests = @import("pane_attachment_requests.zig");
pub const pane_frame_delivery = @import("pane_frame_delivery.zig");
pub const pane_geometry_delivery = @import("pane_geometry_delivery.zig");
pub const pane_graphics = @import("pane_graphics.zig");
pub const pane_open_delivery = @import("pane_open_delivery.zig");
pub const pane_resource_release = @import("pane_resource_release.zig");
pub const pane_split_confirmation_delivery = @import("pane_split_confirmation_delivery.zig");
pub const pane_viewport_delivery = @import("pane_viewport_delivery.zig");
pub const resize_pane = @import("resize_pane.zig");
pub const set_pane_viewport = @import("set_pane_viewport.zig");
pub const split_pane = @import("split_pane.zig");
pub const toggle_pane_fullscreen = @import("toggle_pane_fullscreen.zig");

test {
    _ = active_pane_resource_delivery;
    _ = attach_pane;
    _ = close_pane;
    _ = focus_pane;
    _ = pane_closure_delivery;
    _ = pane_focus_reporting;
    _ = pane_frame;
    _ = pane_attachment_requests;
    _ = pane_frame_delivery;
    _ = pane_geometry_delivery;
    _ = pane_graphics;
    _ = pane_open_delivery;
    _ = pane_resource_release;
    _ = pane_split_confirmation_delivery;
    _ = pane_viewport_delivery;
    _ = resize_pane;
    _ = set_pane_viewport;
    _ = split_pane;
    _ = toggle_pane_fullscreen;
}
