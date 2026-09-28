const keyinput = @import("keyinput");
const data = @import("model");
const core = @import("telar-core");
const Generation = @import("config/Generation.zig");
const Registry = @import("plugins/Registry.zig");
const std = @import("std");
const GuiConfig = @import("config/GuiConfig.zig");
const MachineTarget = @import("machines/MachineTarget.zig").MachineTarget;
const RemoteMachine = @import("machines/RemoteMachine.zig");
const Options = @This();

arguments: []const []const u8,
cwd: []const u8,
endpoint: []const u8,
/// The machine the client connects to by itself. Null when the adapter
/// hands it a socket that is already connected; such a client cannot
/// reconnect.
machine: ?MachineTarget = null,
/// A remote machine a window opens beside its own and shows first, as
/// `telar gui --remote` asks.
open_machine: ?RemoteMachine = null,
/// Process environment used to expand `~` and `$VAR` in typed directories.
environ: std.process.Environ = .empty,
/// The telar binary that runs plugin workers; null is this executable.
telar_executable: ?[]const u8 = null,
prefix: keyinput.Key = data.keybind.default_prefix,
bindings: []const data.config_values.ConfiguredBinding = &.{},
theme: data.ColorTheme = data.theme_support.default_theme,
gui: GuiConfig = .{},
icon_theme: data.icons.Theme = .unicode,
sidebar_visible: bool = true,
pane_gaps: bool = true,
sound: data.SoundPolicy = .{},
bars: data.BarLayout = .{},
input_sequence_timeout_ns: u64 = data.keybind.default_sequence_timeout_ns,
lua_generation: ?*Generation = null,
config_path: ?[]const u8 = null,
config_mtime_ns: i128 = 0,
theme_locked: bool = false,
plugin_registry: ?*Registry = null,
trust_store: ?*core.TrustStore = null,
trust_path: ?[]const u8 = null,
profile: ?[]const u8 = null,
/// Environment fallback for local file links; client.editor takes precedence.
editor: []const u8 = "",
