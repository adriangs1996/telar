const CallbackRefType = @import("../input/CallbackRef.zig");

pub const LuaActionCommand = union(enum) {
    callback: CallbackRefType,
    expression: CallbackRefType,
};
