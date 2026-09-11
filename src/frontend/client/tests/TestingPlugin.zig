const TestingPlugin = @This();
const input_capability = @import("../../input/root.zig");
const core = @import("telar-core");
action: input_capability.action.PluginAction,
digest: core.plugin.Digest,
