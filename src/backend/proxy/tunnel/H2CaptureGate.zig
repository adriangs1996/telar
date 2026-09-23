const Credential = @import("../Credential.zig");
const CaptureGate = @This();

pub fn accepts(_: *anyopaque, _: *const Credential) bool {
    return true;
}
