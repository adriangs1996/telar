const Effects = @This();
const source_namespace = @import("key_routing.zig");
const PaneCommand = @import("PaneCommand.zig");
context: *anyopaque,
close_modal: *const fn (*anyopaque) void,
prompt: *const fn (*anyopaque, source_namespace.Command) anyerror!void,
copy_key: *const fn (*anyopaque, source_namespace.keybind.Key) anyerror!void,
pane: *const fn (*anyopaque, PaneCommand) anyerror!?source_namespace.schema.PaneId,
preview: *const fn (*anyopaque) anyerror!void,
