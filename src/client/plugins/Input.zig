const CallbackContextType = @import("../config/CallbackContext.zig");
const Input = @This();

entry_path: []const u8,
action_name: []const u8,
context: CallbackContextType,
