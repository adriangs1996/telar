const std = @import("std");
pub const Support = enum { unknown, unsupported, supported };

test {
    std.testing.refAllDecls(@This());
}
