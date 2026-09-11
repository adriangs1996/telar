const types = @import("../../agent/types.zig");
const middleware = @import("../middleware.zig");
const TransformCase = @This();

dialect: types.ApiDialect = .anthropic_messages,
direction: middleware.Direction = .request,
kind: middleware.HeaderKind = .request,
method: []const u8 = "POST",
target: []const u8 = "/v1/messages",
encoding: ?[]const u8 = "gzip, br",
