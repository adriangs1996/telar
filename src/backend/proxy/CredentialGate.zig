const CredentialGate = @This();
const identity = @import("identity.zig");
context: *anyopaque,
is_live: *const fn (*anyopaque, *const identity.Credential) bool,

pub fn accepts(gate: CredentialGate, credential: *const identity.Credential) bool {
    return gate.is_live(gate.context, credential);
}
