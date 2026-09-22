const core = @import("telar-core");
const SoundPolicy = @import("../config/SoundPolicy.zig");
const SoundSnapshot = @This();

configuration: SoundPolicy,
active: bool,
queued: ?core.AgentSound,
