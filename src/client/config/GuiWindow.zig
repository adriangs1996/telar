//! Native window preferences; colors remain in the shared theme.
const builtin = @import("builtin");
const GuiPadding = @import("GuiPadding.zig");

/// macOS fuses telar's top bar with the window edge, the traffic lights
/// sharing its row, so the native titlebar starts hidden there. Wayland keeps
/// the compositor decoration by default.
pub const default_titlebar = builtin.os.tag != .macos;

background_opacity: f32 = 1,
background_blur: u8 = 0,
titlebar: bool = default_titlebar,
padding: GuiPadding = .{},
