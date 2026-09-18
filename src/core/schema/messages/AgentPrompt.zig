const id = @import("../id.zig");
request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
text: []const u8,
images: @import("../../AgentImagePaths.zig") = .{},
options: @import("../../AgentOptions.zig") = .{},
