const std = @import("std");
const schema = @import("schema/messages.zig");

test {
    std.testing.refAllDecls(schema);
}
