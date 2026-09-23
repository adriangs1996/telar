const Credential = @import("Credential.zig");
/// Decides whether a credential still names a live pane generation. The
/// proxy service is the one production implementation; the function pointer
/// stays because the observation and capture queue tests inject a fixed
/// liveness without starting a service.
const CredentialGate = @This();

context: *anyopaque,
is_live: *const fn (*anyopaque, *const Credential) bool,

pub fn accepts(gate: CredentialGate, credential: *const Credential) bool {
    return gate.is_live(gate.context, credential);
}
