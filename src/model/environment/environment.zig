const std = @import("std");
pub const Support = @import("../types/EnvironmentSupport.zig").EnvironmentSupport;

test {
    std.testing.refAllDecls(@This());
}
