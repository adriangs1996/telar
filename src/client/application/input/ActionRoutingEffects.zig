const Effects = @This();
const source_namespace = @import("action_routing.zig");
const lua_action = @import("lua_action.zig");
context: *anyopaque,
native: *const fn (*anyopaque, source_namespace.Action) anyerror!source_namespace.Control,
lua: *const fn (*anyopaque, lua_action.Command) anyerror!lua_action.Outcome,
plugin: *const fn (*anyopaque, source_namespace.PluginAction) anyerror!void,
key: *const fn (*anyopaque, source_namespace.keybind.Key) anyerror!void,
paste: *const fn (*anyopaque, []const u8) anyerror!void,
