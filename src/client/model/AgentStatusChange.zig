const AgentKeyType = @import("../agents/AgentKey.zig");
const AgentProviderType = @import("telar-core").AgentProvider;
const AgentStatusType = @import("telar-core").AgentStatus;
const AgentStatusChange = @This();

key: AgentKeyType,
pane_index: u16,
provider: AgentProviderType,
previous: AgentStatusType,
current: AgentStatusType,
