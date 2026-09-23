const core = @import("telar-core");
const AgentKey = @import("../agents/AgentKey.zig");
const AgentStatusChange = @This();

key: AgentKey,
pane_index: u16,
provider: core.AgentProvider,
previous: core.AgentStatus,
current: core.AgentStatus,
