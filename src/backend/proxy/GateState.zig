const GateState = @This();
const identity = @import("identity.zig");
const CredentialGate = @import("CredentialGate.zig");
live_generation: u64 = 1,

fn isLive(context: *anyopaque, credential: *const identity.Credential) bool {
    const state: *GateState = @ptrCast(@alignCast(context));
    return credential.pane_generation == state.live_generation;
}

pub fn gate(state: *GateState) CredentialGate {
    return .{ .context = state, .is_live = isLive };
}
