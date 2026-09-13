//! Every dependency of native hit testing, independent of GPU preparation.
const client = @import("telar-client");
const GuiClient = @import("../GuiClient.zig");
const Stamp = @This();

cell: [2]u16,
mods: u32,
model: client.Version,
geometry: u64,
chrome: u64,
chrome_gesture: ?u8,
sidebar_resize: bool,
overlay_gesture: ?u8,

/// Captures only values; no model or hit-map pointer escapes.
/// Example: `const stamp = HoverStamp.capture(gui, cell, mods);`
pub fn capture(gui: *const GuiClient, cell: [2]u16, mods: u32) Stamp {
    return .{ .cell = cell, .mods = mods, .model = gui.app.model.version(), .geometry = gui.input.pointer.revision, .chrome = gui.chrome.revision, .chrome_gesture = gui.chrome.gesture_button, .sidebar_resize = gui.chrome.sidebar_resize_active, .overlay_gesture = gui.overlays.gesture };
}
