const Options = @This();
const source_namespace = @import("Client.zig");
const lua_config = @import("../config/root.zig");
const bars_capability = @import("../bars/root.zig");
const plugin_broker = @import("../plugins/root.zig");
const core = @import("telar-core");
arguments: []const []const u8,
cwd: []const u8,
endpoint: []const u8,
prefix: source_namespace.keybind.Key = source_namespace.keybind.default_prefix,
bindings: []const source_namespace.ConfiguredBinding = &.{},
theme: source_namespace.theme.Theme = source_namespace.theme.default_theme,
icon_theme: source_namespace.icons.Theme = .unicode,
sidebar_rendering: source_namespace.kitty.SidebarRendering = .automatic,
sidebar_visible: bool = true,
pane_gaps: bool = true,
sound: lua_config.SoundConfig = .{},
bars: bars_capability.Layout = .{},
host_shared_memory: bool = false,
input_escape_timeout_ns: u64 = source_namespace.keybind.default_escape_timeout_ns,
input_sequence_timeout_ns: u64 = source_namespace.keybind.default_sequence_timeout_ns,
lua_generation: ?*lua_config.Generation = null,
config_path: ?[]const u8 = null,
config_mtime_ns: i128 = 0,
theme_locked: bool = false,
sidebar_renderer_locked: bool = false,
plugin_registry: ?*plugin_broker.Registry = null,
trust_store: ?*core.plugin.TrustStore = null,
trust_path: ?[]const u8 = null,
profile: ?[]const u8 = null,
/// Executable used for local `file://` links. Empty disables file opening.
editor: []const u8 = "",
