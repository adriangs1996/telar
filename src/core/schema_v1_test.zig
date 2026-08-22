const std = @import("std");
const v2 = @import("schema/v1.zig");

test {
    std.testing.refAllDecls(v2);
}
