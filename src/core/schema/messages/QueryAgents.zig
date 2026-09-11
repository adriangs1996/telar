/// One-shot request for the current agent snapshot. The reply is the same
/// `agent_snapshot` message that runtime-state subscribers receive.
const QueryAgents = @This();
const source_namespace = @import("agent.zig");
request_id: source_namespace.RequestId,
