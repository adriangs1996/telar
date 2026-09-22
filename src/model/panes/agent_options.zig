const core = @import("telar-core");

pub const Change = union(enum) {
    model: []const u8,
    effort: core.AgentEffort,
    access: core.AgentAccess,
};
