const AgentSoundType = @import("telar-core").AgentSound;
const Effects = @This();

context: *anyopaque,
schedule: *const fn (*anyopaque, AgentSoundType) anyerror!void,
