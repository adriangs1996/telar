/// How an agent's login on a machine stood when `telar machine setup` last
/// looked: started and waiting for the person, confirmed by the agent's own
/// status command, or given up. It is what setup saw, not a live fact.
pub const AgentLogin = enum {
    pending,
    done,
    failed,
};
