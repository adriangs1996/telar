const Failure = @This();
const lua_config = @import("../../config/root.zig");
reason: anyerror,
diagnostic: lua_config.Diagnostic,
