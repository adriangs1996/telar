const id = @import("schema/id.zig");
const Cursor = @import("AgentHistoryCursor.zig");
const AgentThreadSnapshot = @import("AgentThreadSnapshot.zig");

request_id: id.RequestId,
view_generation: u64,
snapshot: AgentThreadSnapshot,
before: Cursor = .{},
after: Cursor = .{},
has_before: bool = false,
has_after: bool = false,
