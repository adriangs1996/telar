const spawn = @import("spawn.zig");

pub const ChildFailure = extern struct {
    stage: spawn.ChildFailureStage,
    errno_code: c_int,
};
