const Effects = @This();
const source_namespace = @import("agent_sound.zig");
context: *anyopaque,
schedule: *const fn (*anyopaque, source_namespace.schema.AgentSound) anyerror!void,
