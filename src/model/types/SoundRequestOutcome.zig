const core = @import("telar-core");

pub const SoundRequestOutcome = union(enum) {
    ignored,
    queued,
    start: core.AgentSound,
};
