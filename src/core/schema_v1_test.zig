const std = @import("std");
const v1 = @import("schema/v1.zig");

test {
    std.testing.refAllDecls(v1);
}
