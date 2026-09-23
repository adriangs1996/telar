const Credential = @import("Credential.zig");
const CredentialGate = @import("CredentialGate.zig");
const GateState = @This();

live_generation: u64 = 1,

fn isLive(context: *anyopaque, credential: *const Credential) bool {
    const state: *GateState = @ptrCast(@alignCast(context));
    return credential.pane_generation == state.live_generation;
}

pub fn gate(self: *GateState) CredentialGate {
    return .{ .context = self, .is_live = isLive };
}
