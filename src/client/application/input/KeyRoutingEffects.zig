const key_routing = @import("key_routing.zig");
const KeyType = @import("../../input/Key.zig");
const PaneCommand = @import("PaneCommand.zig");
const PaneIdType = @import("telar-core").PaneId;
const Effects = @This();

context: *anyopaque,
close_modal: *const fn (*anyopaque) void,
prompt: *const fn (*anyopaque, key_routing.Command) anyerror!void,
copy_key: *const fn (*anyopaque, KeyType) anyerror!void,
pane: *const fn (*anyopaque, PaneCommand) anyerror!?PaneIdType,
preview: *const fn (*anyopaque) anyerror!void,
