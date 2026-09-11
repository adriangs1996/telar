const id = @import("../id.zig");
/// One-shot request for the current agent snapshot. The reply is the same
/// `agent_snapshot` message that runtime-state subscribers receive.
const QueryAgents = @This();

request_id: id.RequestId,
