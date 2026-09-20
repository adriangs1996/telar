const core = @import("telar-core");

text: []const u8,
images: core.AgentImagePaths = .{},
model: ?[]const u8 = null,
effort: ?core.AgentEffort = null,
access: ?core.AgentAccess = null,
