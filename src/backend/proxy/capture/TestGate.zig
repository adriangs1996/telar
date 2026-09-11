const CredentialType = @import("../Credential.zig");
const TestGate = @This();

pub fn accepts(_: *anyopaque, _: *const CredentialType) bool {
    return true;
}
