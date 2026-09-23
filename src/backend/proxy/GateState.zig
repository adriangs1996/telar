const Credential = @import("Credential.zig");
const CredentialGate = @import("CredentialGate.zig");
const GateState = @This();

live_generation: u64 = 1,

fn isLive(context: *anyopaque, credential: *const Credential) bool {
    const state: *GateState = @ptrCast(@alignCast(context));
    return credential.pane_generation == state.live_generation;
}

pub fn gate(state: *GateState) CredentialGate {
    return .{ .context = state, .is_live = isLive };
}
