const types = @import("../types.zig");
const RequestRuntimeState = @This();

client_identity: types.ClientIdentity,
interactive: bool = true,

/// Rejects identities that cannot own retained runtime state.
///
/// ```zig
/// try request.validateWire();
/// ```
pub fn validateWire(self: RequestRuntimeState) !void {
    if (self.client_identity == .invalid) {
        return error.InvalidClientIdentity;
    }
}
