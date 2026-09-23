const CallbackRef = @import("../input/CallbackRef.zig");

pub const LuaActionCommand = union(enum) {
    callback: CallbackRef,
    expression: CallbackRef,
};
