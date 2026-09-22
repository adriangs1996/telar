const LocalAgentNavigation = @import("../state/LocalAgentNavigation.zig");
const AgentHandoff = @import("../state/AgentHandoff.zig");

pub const AgentNavigationPlan = union(enum) {
    local: LocalAgentNavigation,
    handoff: AgentHandoff,
};
