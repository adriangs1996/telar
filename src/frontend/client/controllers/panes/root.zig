//! Client adapters for pane lifecycle and synchronization.

pub const active_pane_resources = @import("active_pane_resources.zig");
pub const pane_attachments = @import("pane_attachments.zig");
pub const pane_clipboards = @import("pane_clipboards.zig");
pub const pane_closures = @import("pane_closures.zig");
pub const pane_focus = @import("pane_focus.zig");
pub const pane_focus_commands = @import("pane_focus_commands.zig");
pub const pane_focus_reports = @import("pane_focus_reports.zig");
pub const pane_frames = @import("pane_frames.zig");
pub const pane_geometry = @import("pane_geometry.zig");
pub const pane_graphics = @import("pane_graphics.zig");
pub const pane_metadata = @import("pane_metadata.zig");
pub const pane_openings = @import("pane_openings.zig");
pub const pane_resources = @import("pane_resources.zig");
pub const pane_splits = @import("pane_splits.zig");
pub const pane_viewports = @import("pane_viewports.zig");

test {
    _ = active_pane_resources;
    _ = pane_attachments;
    _ = pane_clipboards;
    _ = pane_closures;
    _ = pane_focus;
    _ = pane_focus_commands;
    _ = pane_focus_reports;
    _ = pane_frames;
    _ = pane_geometry;
    _ = pane_graphics;
    _ = pane_metadata;
    _ = pane_openings;
    _ = pane_resources;
    _ = pane_splits;
    _ = pane_viewports;
}
