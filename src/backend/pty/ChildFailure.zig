const ChildFailureStage = @import("spawn.zig").ChildFailureStage;

pub const ChildFailure = extern struct {
    stage: ChildFailureStage,
    errno_code: c_int,
};
