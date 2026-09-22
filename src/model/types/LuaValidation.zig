const Failure = @import("../application/input/Failure.zig");

pub const LuaValidation = union(enum) {
    valid,
    failed: Failure,
};
