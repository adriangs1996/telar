//! Small UI components and the explicit composition root for client chrome.

const std = @import("std");
const context = @import("context.zig");

pub const layout = @import("layout.zig");
pub const sidebar_model = @import("sidebar_model.zig");
pub const workspace_model = @import("workspace_model.zig");
pub const notification = @import("notification.zig");
pub const toast = @import("toast.zig");
pub const top_bar = @import("top_bar.zig");
pub const sidebar = @import("sidebar.zig");
pub const tab_bar = @import("tab_bar.zig");
pub const tab_rename = @import("tab_rename.zig");
pub const status_bar = @import("status_bar.zig");
pub const workbench = @import("workbench.zig");
pub const attachment_preview = @import("attachment_preview.zig");
pub const composition = @import("composition.zig");

pub const Action = context.Action;
pub const Hits = context.Hits;
pub const Context = context.Context;
pub const Cursor = context.Cursor;

test {
    std.testing.refAllDecls(@This());
}
