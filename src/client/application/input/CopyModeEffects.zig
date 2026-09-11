const CopyModeEffects = @This();
const source_namespace = @import("copy_mode.zig");
const input_capability = @import("../../input/root.zig");
const link_capability = @import("../../links/root.zig");
const set_pane_viewport = @import("../panes/root.zig").set_pane_viewport;
context: *anyopaque,
copy: *const fn (*anyopaque, source_namespace.schema.CopySelection) anyerror!void,
open_search: *const fn (*anyopaque, input_capability.copy_mode.Direction) anyerror!void,
open_link: *const fn (*anyopaque, link_capability.Target) anyerror!void,
viewport: set_pane_viewport.PaneViewportEffects,
