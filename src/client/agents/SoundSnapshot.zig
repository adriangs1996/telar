const ConfigType = @import("../config/SoundPolicy.zig");
const AgentSound = @import("telar-core").AgentSound;
const SoundSnapshot = @This();

configuration: ConfigType,
active: bool,
queued: ?AgentSound,
