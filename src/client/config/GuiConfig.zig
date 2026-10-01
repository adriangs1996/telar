//! Typed native-host preferences. No Lua values or host resources are retained.
const core = @import("telar-core");
const std = @import("std");
const GuiFont = @import("GuiFont.zig");
const GuiCursor = @import("GuiCursor.zig");
const GuiWindow = @import("GuiWindow.zig");
const GuiChrome = @import("GuiChrome.zig");
const GuiSidebar = @import("GuiSidebar.zig");

font: GuiFont = .{},
cursor: GuiCursor = .{},
window: GuiWindow = .{},
chrome: GuiChrome = .{},
sidebar: GuiSidebar = .{},
/// Caps the window's frame rate below its display's. Null presents at the
/// display's rate.
max_fps: ?u16 = null,

/// The lowest `max_fps` accepts: the slowest cadence the runtime paces cell
/// frames at, 30 Hz.
pub const min_fps_cap: u16 = std.time.ns_per_s / core.max_frame_interval_ns;
/// The highest `max_fps` accepts: the fastest cadence the runtime paces cell
/// frames at, 240 Hz.
pub const max_fps_cap: u16 = std.time.ns_per_s / core.min_frame_interval_ns;
