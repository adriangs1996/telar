const id = @import("schema/id.zig");
const Cursor = @import("AgentHistoryCursor.zig");

request_id: id.RequestId,
view_generation: u64,
snapshot: @import("AgentThreadSnapshot.zig"),
before: Cursor = .{},
after: Cursor = .{},
has_before: bool = false,
has_after: bool = false,
