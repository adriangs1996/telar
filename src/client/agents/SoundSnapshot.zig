const core = @import("telar-core");
const ConfigType = @import("../config/SoundPolicy.zig");
const SoundSnapshot = @This();

configuration: ConfigType,
active: bool,
queued: ?core.AgentSound,
