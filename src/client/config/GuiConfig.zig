//! Typed native-host preferences. No Lua values or host resources are retained.
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
