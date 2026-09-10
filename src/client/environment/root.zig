pub const Support = enum { unknown, unsupported, supported };

test {
    @import("std").testing.refAllDecls(@This());
}
