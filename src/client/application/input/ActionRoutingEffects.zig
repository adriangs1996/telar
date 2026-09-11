const action = @import("../../input/action.zig");
const action_routing = @import("action_routing.zig");
const lua_action = @import("lua_action.zig");
const PluginActionType = @import("../../input/PluginAction.zig");
const KeyType = @import("../../input/Key.zig");
const Effects = @This();

context: *anyopaque,
native: *const fn (*anyopaque, action.Action) anyerror!action_routing.Control,
lua: *const fn (*anyopaque, lua_action.Command) anyerror!lua_action.Outcome,
plugin: *const fn (*anyopaque, PluginActionType) anyerror!void,
key: *const fn (*anyopaque, KeyType) anyerror!void,
paste: *const fn (*anyopaque, []const u8) anyerror!void,
