const RequestRuntimeState = @This();
const source_namespace = @import("runtime.zig");
client_identity: source_namespace.ClientIdentity,

/// Rejects identities that cannot own retained runtime state.
///
/// ```zig
/// try request.validateWire();
/// ```
pub fn validateWire(message: RequestRuntimeState) !void {
    if (message.client_identity == .invalid) {
        return error.InvalidClientIdentity;
    }
}
