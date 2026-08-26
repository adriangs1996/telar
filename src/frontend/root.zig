//! The disposable side of telar.
//!
//! The frontend owns the real terminal, frame pacing and interactive UI state.
//! It consumes core data and never reaches into backend process state.

const core = @import("telar-core");

pub const ui = @import("ui/root.zig");
pub const select = core.select;
pub const theme = ui.theme;
pub const input = @import("input/root.zig");
pub const presentation = @import("presentation/root.zig");
pub const workspace = @import("workspace/root.zig");
pub const graphics = @import("graphics/root.zig");
pub const config = @import("config/root.zig");
pub const plugins = @import("plugins/root.zig");
pub const platform = @import("platform/root.zig");
pub const transport = @import("transport/root.zig");
pub const client = @import("client/root.zig");
pub const widgets = @import("widgets/root.zig");

// Compatibility aliases for callers migrating to the capability namespaces.
pub const term = presentation.screen;
pub const diff = presentation.diff;
pub const frame = presentation.frame;
pub const pace = presentation.pace;
pub const edit = input.edit;
pub const keybind = input.keybind;
pub const action = input.action;
pub const host_input = input.host;
pub const kitty = graphics.kitty;
pub const text_rasterizer = graphics.rasterizer;
pub const toast_graphics = graphics.toast;
pub const layout = workspace.layout;
pub const multiplexer = workspace.multiplexer;
pub const tabs = workspace.tabs;

test {
    @import("std").testing.refAllDecls(@This());
    // Capability suites with no test root of their own are collected here,
    // in the package root, rather than under an unrelated capability.
    _ = @import("presentation/root.zig");
    _ = @import("graphics/root.zig");
    _ = @import("workspace/root.zig");
    _ = @import("ui/root.zig");
    _ = @import("platform/root.zig");
}
