const PaneIdentity = @This();
const pane_mod = @import("../../pane/root.zig");
const source_namespace = @import("pane_launcher.zig");
key: pane_mod.PaneKey,
location: source_namespace.schema.TabLocation,
socket_path: []const u8,
executable_path: []const u8,
