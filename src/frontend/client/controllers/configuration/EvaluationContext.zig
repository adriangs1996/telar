const EvaluationContext = @This();
const Client = @import("../../Client.zig");
const lua_config = @import("../../../config/root.zig");
client: *Client,
diagnostic: lua_config.Diagnostic = .{},
