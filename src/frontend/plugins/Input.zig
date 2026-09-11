const Input = @This();
const lua_config = @import("../config/root.zig");
entry_path: []const u8,
action_name: []const u8,
context: lua_config.CallbackContext,
