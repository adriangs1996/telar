const ThemeType = @import("../ui/Theme.zig");
const theme_module = @import("../ui/theme_support.zig");
const ClientTheme = @import("telar-client").Theme;
const capabilities = @import("../graphics/capabilities.zig");
const model = @import("model.zig");
const Config = @import("../sound/Config.zig");
const Delivery = @import("telar-client").Delivery;
const ConfigurationType = @import("telar-client").Configuration;
const KeyType = @import("telar-client").Key;
const default_prefix_module = @import("telar-client").default_prefix;
const default_escape_timeout_ns_module = @import("telar-client").default_escape_timeout_ns;
const default_sequence_timeout_ns_module = @import("telar-client").default_sequence_timeout_ns;
const RuntimeSnapshot = @import("RuntimeSnapshot.zig");
const PluginSpec = @import("PluginSpec.zig");
const Snapshot = @This();

theme: ThemeType = theme_module.default_theme,
icon_theme: ClientTheme = .unicode,
sidebar_rendering: capabilities.SidebarRendering = .automatic,
sidebar_visible: bool = true,
pane_gaps: bool = true,
window_title_bytes: [model.max_window_title_bytes]u8 = undefined,
window_title_len: u8 = 0,
sound: Config = .{},
notification_delivery: Delivery = .telar,
history_show_agent_commands: bool = false,
history_enter_runs: bool = false,
history_match_fts: bool = false,
theme_light: ?ThemeType = null,
theme_dark: ?ThemeType = null,
bars: ConfigurationType = .{},
prefix: KeyType = default_prefix_module,
input_escape_timeout_ns: u64 = default_escape_timeout_ns_module,
input_sequence_timeout_ns: u64 = default_sequence_timeout_ns_module,
bindings: [model.max_bindings]model.ConfiguredBinding = undefined,
bindings_prefixed: [model.max_bindings]bool = undefined,
binding_count: u16 = 0,
runtime: RuntimeSnapshot = .{},
plugins: [model.max_plugins]PluginSpec = undefined,
plugin_count: u8 = 0,

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
