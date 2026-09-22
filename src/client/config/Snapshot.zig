const icons = @import("../layout/icons.zig");
const sidebar_rendering_module = @import("sidebar_rendering.zig");
const data = @import("model");
const ThemeType = @import("../appearance/Theme.zig");
const theme_module = @import("../appearance/theme_support.zig");
const model = @import("model.zig");
const ConfigurationType = @import("../bars/Configuration.zig");
const RuntimeSnapshot = @import("RuntimeSnapshot.zig");
const PluginSpec = @import("PluginSpec.zig");
const Snapshot = @This();

theme: ThemeType = theme_module.default_theme,
gui: @import("GuiConfig.zig") = .{},
icon_theme: icons.Theme = .unicode,
sidebar_rendering: sidebar_rendering_module.SidebarRendering = .automatic,
sidebar_visible: bool = true,
pane_gaps: bool = true,
editor_bytes: [model.max_editor_bytes]u8 = undefined,
editor_len: u16 = 0,
window_title_bytes: [model.max_window_title_bytes]u8 = undefined,
window_title_len: u8 = 0,
sound: data.SoundPolicy = .{},
notification_delivery: data.NotificationDelivery = .telar,
history_show_agent_commands: bool = false,
history_enter_runs: bool = false,
history_match_fts: bool = false,
theme_light: ?ThemeType = null,
theme_dark: ?ThemeType = null,
bars: ConfigurationType = .{},
prefix: data.Key = data.keybind.default_prefix,
input_escape_timeout_ns: u64 = data.keybind.default_escape_timeout_ns,
input_sequence_timeout_ns: u64 = data.keybind.default_sequence_timeout_ns,
bindings: [model.max_bindings]model.ConfiguredBinding = undefined,
bindings_prefixed: [model.max_bindings]bool = undefined,
binding_count: u16 = 0,
runtime: RuntimeSnapshot = .{},
plugins: [model.max_plugins]PluginSpec = undefined,
plugin_count: u8 = 0,

/// Resolves a complete theme with identical CLI/appearance precedence for both hosts.
/// Example: `const theme = snapshot.resolveTheme(.dark, null);`
pub fn resolveTheme(snapshot: *const Snapshot, appearance: data.HostAppearance, locked: ?ThemeType) ThemeType {
    return locked orelse (switch (appearance) {
        .unknown => null,
        .light => snapshot.theme_light,
        .dark => snapshot.theme_dark,
    } orelse snapshot.theme);
}

pub fn bindingSlice(snapshot: *const Snapshot) []const model.ConfiguredBinding {
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

/// Chooses the configured executable before the process environment fallback.
/// Example: `const executable = snapshot.resolveEditor(environment_editor);`
pub fn resolveEditor(self: *const Snapshot, fallback: []const u8) []const u8 {
    return if (self.editor_len != 0) self.editor_bytes[0..self.editor_len] else fallback;
}
