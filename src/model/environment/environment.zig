const std = @import("std");
pub const Support = @import("EnvironmentSupport.zig").EnvironmentSupport;

test {
    std.testing.refAllDecls(@This());
}
