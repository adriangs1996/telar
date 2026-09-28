const keyinput = @import("keyinput");
const data = @import("model");
const RuntimeSnapshot = @import("RuntimeSnapshot.zig");
const GuiConfig = @import("GuiConfig.zig");
const retired_config = @import("retired_config.zig");
const Snapshot = @This();

/// Keys only the retired terminal client used that this file still sets;
/// they are ignored and reported (`retired_config`).
retired: retired_config.Set = .initEmpty(),

theme: data.ColorTheme = data.theme_support.default_theme,
gui: GuiConfig = .{},
sidebar_visible: bool = true,
pane_gaps: bool = true,
editor_bytes: [data.config_values.max_editor_bytes]u8 = undefined,
editor_len: u16 = 0,
window_title_bytes: [data.config_values.max_window_title_bytes]u8 = undefined,
window_title_len: u8 = 0,
sound: data.SoundPolicy = .{},
notification_delivery: data.NotificationDelivery = .telar,
history_show_agent_commands: bool = false,
history_enter_runs: bool = false,
history_match_fts: bool = false,
theme_light: ?data.ColorTheme = null,
theme_dark: ?data.ColorTheme = null,
bars: data.BarConfiguration = .{},
prefix: keyinput.Key = data.keybind.default_prefix,
input_sequence_timeout_ns: u64 = data.keybind.default_sequence_timeout_ns,
bindings: [data.config_values.max_bindings]data.config_values.ConfiguredBinding = undefined,
bindings_prefixed: [data.config_values.max_bindings]bool = undefined,
binding_count: u16 = 0,
runtime: RuntimeSnapshot = .{},
plugins: [data.config_values.max_plugins]data.PluginSpec = undefined,
plugin_count: u8 = 0,

/// Resolves a complete theme with identical CLI/appearance precedence for both hosts.
/// Example: `const theme = snapshot.resolveTheme(.dark, null);`
pub fn resolveTheme(self: *const Snapshot, appearance: data.HostAppearance, locked: ?data.ColorTheme) data.ColorTheme {
    return locked orelse (switch (appearance) {
        .unknown => null,
        .light => self.theme_light,
        .dark => self.theme_dark,
    } orelse self.theme);
}

pub fn bindingSlice(self: *const Snapshot) []const data.config_values.ConfiguredBinding {
    return self.bindings[0..self.binding_count];
}

/// The host window title template; empty leaves the host title alone.
///
/// ```zig
/// const template = snapshot.windowTitle();
/// ```
pub fn windowTitle(self: *const Snapshot) []const u8 {
    return self.window_title_bytes[0..self.window_title_len];
}

/// Chooses the configured executable before the process environment fallback.
/// Example: `const executable = snapshot.resolveEditor(environment_editor);`
pub fn resolveEditor(self: *const Snapshot, fallback: []const u8) []const u8 {
    return if (self.editor_len != 0) self.editor_bytes[0..self.editor_len] else fallback;
}
