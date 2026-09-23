const Credential = @import("../Credential.zig");
const TestGate = @This();

pub fn accepts(_: *anyopaque, _: *const Credential) bool {
    return true;
}
