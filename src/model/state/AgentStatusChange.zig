const core = @import("telar-core");
const AgentKey = @import("../agents/AgentKey.zig");

key: AgentKey,
pane_index: u16,
provider: core.AgentProvider,
previous: core.AgentStatus,
current: core.AgentStatus,
