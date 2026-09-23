const AgentImagePaths = @import("AgentImagePaths.zig");
const AgentOptions = @import("AgentOptions.zig");

text: []const u8,
images: AgentImagePaths = .{},
options: AgentOptions,
