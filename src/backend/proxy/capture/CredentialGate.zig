const CredentialType = @import("../Credential.zig");
const CredentialGate = @This();

context: *anyopaque,
is_live: *const fn (*anyopaque, *const CredentialType) bool,

pub fn accepts(gate: CredentialGate, credential: *const CredentialType) bool {
    return gate.is_live(gate.context, credential);
}
