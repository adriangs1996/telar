const core = @import("telar-core");
const AgentKeyType = @import("../agents/AgentKey.zig");
const AgentStatusChange = @This();

key: AgentKeyType,
pane_index: u16,
provider: core.AgentProvider,
previous: core.AgentStatus,
current: core.AgentStatus,
