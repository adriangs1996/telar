const data = @import("model");
const core = @import("telar-core");
const GenerationType = @import("config/Generation.zig");
const RegistryType = @import("plugins/Registry.zig");
const std = @import("std");
const Options = @This();

arguments: []const []const u8,
cwd: []const u8,
endpoint: []const u8,
/// Process environment used to expand `~` and `$VAR` in typed directories.
environ: std.process.Environ = .empty,
prefix: data.Key = data.keybind.default_prefix,
bindings: []const data.config_values.ConfiguredBinding = &.{},
theme: data.ColorTheme = data.theme_support.default_theme,
gui: @import("config/GuiConfig.zig") = .{},
icon_theme: data.icons.Theme = .unicode,
sidebar_rendering: data.SidebarRendering = .automatic,
sidebar_visible: bool = true,
pane_gaps: bool = true,
sound: data.SoundPolicy = .{},
bars: data.BarLayout = .{},
host_shared_memory: bool = false,
input_escape_timeout_ns: u64 = data.keybind.default_escape_timeout_ns,
input_sequence_timeout_ns: u64 = data.keybind.default_sequence_timeout_ns,
lua_generation: ?*GenerationType = null,
config_path: ?[]const u8 = null,
config_mtime_ns: i128 = 0,
theme_locked: bool = false,
sidebar_renderer_locked: bool = false,
plugin_registry: ?*RegistryType = null,
trust_store: ?*core.TrustStore = null,
trust_path: ?[]const u8 = null,
profile: ?[]const u8 = null,
/// Environment fallback for local file links; client.editor takes precedence.
editor: []const u8 = "",
