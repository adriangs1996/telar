const id = @import("../id.zig");
const types = @import("../types.zig");
const review = @import("../../change_review.zig");
request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
provider: types.AgentProvider,
session: []const u8,
tool_call_id: []const u8,
phase: review.SamplePhase,
path: []const u8,
exists: bool,
content: []const u8,
