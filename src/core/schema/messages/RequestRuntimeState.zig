const types = @import("../types.zig");
const RequestRuntimeState = @This();

client_identity: types.ClientIdentity,

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
