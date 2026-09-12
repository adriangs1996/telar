const KeyType = @import("input/Key.zig");
const default_prefix_module = @import("input/keybind.zig").default_prefix;
const model = @import("config/model.zig");
const ThemeType = @import("appearance/Theme.zig");
const theme_support = @import("appearance/theme_support.zig");
const ClientTheme = @import("layout/icons.zig").Theme;
const SidebarRenderingType = @import("config/sidebar_rendering.zig").SidebarRendering;
const SoundPolicy = @import("config/SoundPolicy.zig");
const LayoutType = @import("bars/BarLayout.zig");
const default_escape_timeout_ns_module = @import("input/keybind.zig").default_escape_timeout_ns;
const default_sequence_timeout_ns_module = @import("input/keybind.zig").default_sequence_timeout_ns;
const GenerationType = @import("config/Generation.zig");
const RegistryType = @import("plugins/Registry.zig");
const TrustStoreType = @import("telar-core").TrustStore;
const Options = @This();

arguments: []const []const u8,
cwd: []const u8,
endpoint: []const u8,
prefix: KeyType = default_prefix_module,
bindings: []const model.ConfiguredBinding = &.{},
theme: ThemeType = theme_support.default_theme,
icon_theme: ClientTheme = .unicode,
sidebar_rendering: SidebarRenderingType = .automatic,
sidebar_visible: bool = true,
pane_gaps: bool = true,
sound: SoundPolicy = .{},
bars: LayoutType = .{},
host_shared_memory: bool = false,
input_escape_timeout_ns: u64 = default_escape_timeout_ns_module,
input_sequence_timeout_ns: u64 = default_sequence_timeout_ns_module,
lua_generation: ?*GenerationType = null,
config_path: ?[]const u8 = null,
config_mtime_ns: i128 = 0,
theme_locked: bool = false,
sidebar_renderer_locked: bool = false,
plugin_registry: ?*RegistryType = null,
trust_store: ?*TrustStoreType = null,
trust_path: ?[]const u8 = null,
profile: ?[]const u8 = null,
/// Executable used for local `file://` links. Empty disables file opening.
editor: []const u8 = "",
