const CaptureGate = @This();
const identity = @import("../identity.zig");
pub fn accepts(_: *anyopaque, _: *const identity.Credential) bool {
    return true;
}
