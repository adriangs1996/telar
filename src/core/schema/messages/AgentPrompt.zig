const id = @import("../id.zig");
const AgentImagePaths = @import("../../AgentImagePaths.zig");
const AgentOptions = @import("../../AgentOptions.zig");
request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
text: []const u8,
images: AgentImagePaths = .{},
options: AgentOptions = .{},
