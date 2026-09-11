const Snapshot = @This();
const theme_module = @import("../ui/root.zig").theme;
const icons = @import("../ui/root.zig").icons;
const kitty = @import("../graphics/root.zig").kitty;
const source_namespace = @import("model.zig");
const bars_module = @import("../bars/root.zig");
const RuntimeSnapshot = @import("RuntimeSnapshot.zig");
const PluginSpec = @import("PluginSpec.zig");
theme: theme_module.Theme = theme_module.default_theme,
icon_theme: icons.Theme = .unicode,
sidebar_rendering: kitty.SidebarRendering = .automatic,
sidebar_visible: bool = true,
pane_gaps: bool = true,
window_title_bytes: [source_namespace.max_window_title_bytes]u8 = undefined,
window_title_len: u8 = 0,
sound: source_namespace.SoundConfig = .{},
notification_delivery: source_namespace.NotificationDelivery = .telar,
history_show_agent_commands: bool = false,
history_enter_runs: bool = false,
history_match_fts: bool = false,
theme_light: ?theme_module.Theme = null,
theme_dark: ?theme_module.Theme = null,
bars: bars_module.Configuration = .{},
prefix: source_namespace.keybind.Key = source_namespace.keybind.default_prefix,
input_escape_timeout_ns: u64 = source_namespace.keybind.default_escape_timeout_ns,
input_sequence_timeout_ns: u64 = source_namespace.keybind.default_sequence_timeout_ns,
bindings: [source_namespace.max_bindings]source_namespace.ConfiguredBinding = undefined,
bindings_prefixed: [source_namespace.max_bindings]bool = undefined,
binding_count: u16 = 0,
runtime: RuntimeSnapshot = .{},
plugins: [source_namespace.max_plugins]PluginSpec = undefined,
plugin_count: u8 = 0,

pub fn bindingSlice(snapshot: *const Snapshot) []const source_namespace.ConfiguredBinding {
    return snapshot.bindings[0..snapshot.binding_count];
}

/// The host window title template; empty leaves the host title alone.
///
/// ```zig
/// const template = snapshot.windowTitle();
/// ```
pub fn windowTitle(snapshot: *const Snapshot) []const u8 {
    return snapshot.window_title_bytes[0..snapshot.window_title_len];
}
