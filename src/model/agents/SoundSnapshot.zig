const core = @import("telar-core");
const SoundPolicy = @import("../config/SoundPolicy.zig");

configuration: SoundPolicy,
active: bool,
queued: ?core.AgentSound,
