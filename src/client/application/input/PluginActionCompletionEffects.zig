const CompletionEffects = @This();
const PluginResult = @import("PluginResult.zig");
const config = @import("../../config/root.zig");
const source_namespace = @import("plugin_action.zig");
context: *anyopaque,
authorize: *const fn (*anyopaque, PluginResult) anyerror!void,
apply: *const fn (*anyopaque, *const config.EffectBatch) anyerror!source_namespace.BatchDisposition,
