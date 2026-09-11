const CredentialType = @import("../Credential.zig");
const CaptureGate = @This();

pub fn accepts(_: *anyopaque, _: *const CredentialType) bool {
    return true;
}
