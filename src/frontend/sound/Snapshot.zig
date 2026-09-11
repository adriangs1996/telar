const ConfigType = @import("Config.zig");
const AgentSound = @import("telar-core").AgentSound;
const Snapshot = @This();

configuration: ConfigType,
active: bool,
queued: ?AgentSound,
