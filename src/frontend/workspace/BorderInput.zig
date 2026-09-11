const BorderInput = @This();
const layout_mod = @import("telar-client").workspace.layout;
const Model = @import("telar-client").workspace.multiplexer.Model;
const source_namespace = @import("multiplexer.zig");
const theme = @import("../ui/root.zig").theme;
view: layout_mod.View,
foreground_name: []const u8,
fullscreen_model: ?*const Model = null,
progress_state: source_namespace.schema.PaneProgressState,
progress_percent: ?u8,
animation_frame: u8,
palette: *const theme.Palette,
