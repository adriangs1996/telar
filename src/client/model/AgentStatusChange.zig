const AgentStatusChange = @This();
const agents = @import("../agents/root.zig");
const source_namespace = @import("types.zig");
key: agents.AgentKey,
pane_index: u16,
provider: source_namespace.schema.AgentProvider,
previous: source_namespace.schema.AgentStatus,
current: source_namespace.schema.AgentStatus,
